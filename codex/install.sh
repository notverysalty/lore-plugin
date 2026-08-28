#!/bin/bash
# lore — Codex installer.
# Installs lore's skills (as lore-* prefixed names) + the gate/push scripts into Codex,
# and merges ~/.codex/hooks.json (existing hooks are preserved).
# Usage:     bash codex/install.sh
# Uninstall: bash codex/install.sh --uninstall
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # the plugin root
# Codex discovers user skills in ~/.agents/skills (per the build-skills docs as of
# codex-cli 0.144.x); ~/.codex/skills is a legacy location older installs used and is
# swept during migration/uninstall but no longer written to.
SKILLS_DST="$HOME/.agents/skills"
LEGACY_SKILLS="$HOME/.codex/skills"
SCRIPTS_DST="$HOME/.codex/lore/scripts"
HOOKS="$HOME/.codex/hooks.json"
SKILLS=(memorize init knowledge-consolidate resolve-merge set-language)

command -v python3 >/dev/null 2>&1 || { echo "python3 is required to merge hooks.json"; exit 1; }

# Ownership check: bare names like memorize/init are generic — a same-named directory
# under ~/.codex/skills/ may be a user's or another source's skill. Only directories
# carrying the legacy lore install signature (agents/openai.yaml display_name starting
# with "lore: ") may be removed during migration/uninstall.
is_lore_skill() {
	grep -q 'display_name: "lore: ' "$1/agents/openai.yaml" 2>/dev/null
}

if [ "${1:-}" = "--uninstall" ]; then
	# lore-* prefixed names are removed directly; bare-name dirs are ownership-checked first.
	# Both the current and the legacy skills locations are swept.
	for s in "${SKILLS[@]}"; do
		for base in "$SKILLS_DST" "$LEGACY_SKILLS"; do
			rm -rf "${base:?}/lore-$s"
			[ -d "$base/$s" ] && is_lore_skill "$base/$s" && rm -rf "${base:?}/$s"
		done
	done
	rm -rf "$HOME/.codex/lore"
	python3 - "$HOOKS" "$SCRIPTS_DST" <<'PY'
import json, os, sys
hp, scripts = sys.argv[1], sys.argv[2]
if not os.path.exists(hp): sys.exit(0)
d = json.load(open(hp))
# Match on the lore scripts directory in a hook's own command, never on the substring
# "lore" anywhere in the group's JSON — that would also delete unrelated groups whose
# commands merely contain the letters (e.g. an explore.sh hook).
def is_lore_group(g):
    return any(scripts in (h.get("command") or "") for h in g.get("hooks", []) if isinstance(h, dict))
for ev in ("Stop", "SessionStart", "PostToolUse"):
    arr = d.get("hooks", {}).get(ev, [])
    if not arr: continue
    kept = [g for g in arr if not is_lore_group(g)]
    if kept: d["hooks"][ev] = kept
    else: del d["hooks"][ev]
tmp = hp + ".tmp"
json.dump(d, open(tmp, "w"), ensure_ascii=False, indent=2)
os.replace(tmp, hp)
PY
	echo "lore uninstalled from Codex. Restart codex to take effect."
	exit 0
fi

# 1. Skills (incl. agents/openai.yaml) — installed under lore-* prefixed names:
#    Codex has no plugin namespace and bare names collide easily; with the prefix,
#    $lore-memorize maps one-to-one to Claude Code's lore:memorize (the SKILL.md
#    frontmatter name and in-body references are rewritten on install).
mkdir -p "$SKILLS_DST"
for s in "${SKILLS[@]}"; do
	dst="$SKILLS_DST/lore-$s"
	rm -rf "$dst"
	# Migration: sweep earlier lore installs from both locations — prefixed copies in the
	# legacy dir, and ownership-checked bare-name dirs (same-named user/foreign skills are
	# kept, with a warning)
	rm -rf "${LEGACY_SKILLS:?}/lore-$s"
	for base in "$SKILLS_DST" "$LEGACY_SKILLS"; do
		if [ -d "$base/$s" ]; then
			if is_lore_skill "$base/$s"; then
				rm -rf "${base:?}/$s"
			else
				echo "⚠️ kept $base/$s: same name but no lore install signature (not installed by this script); remove manually if needed"
			fi
		fi
	done
	cp -R "$PLUGIN_DIR/skills/$s" "$dst"
	# Rewrites, in order: skill name → lore-* ; cross-skill references → lore-* ; the
	# /lore:stats command → the installed script ; and — critically — the <engine-scripts>
	# token to the ABSOLUTE install dir. On Claude Code that path is injected by the
	# write-gate hook at skill invocation; Codex has no such channel, so it is baked in here.
	# sed replacement strings must escape &, \ and the | delimiter, or an unusual $HOME
	# would corrupt every rewritten command
	scripts_esc=$(printf '%s' "$SCRIPTS_DST" | sed 's/[&\\|]/\\&/g')
	sed -e "s/^name: $s\$/name: lore-$s/" \
		-e 's/lore:memorize/lore-memorize/g' \
		-e 's/lore:init/lore-init/g' \
		-e 's/lore:knowledge-consolidate/lore-knowledge-consolidate/g' \
		-e 's/lore:resolve-merge/lore-resolve-merge/g' \
		-e 's/lore:set-language/lore-set-language/g' \
		-e 's|/lore:stats|lore-stats.sh|g' \
		-e "s|<engine-scripts>|$scripts_esc|g" \
		-e 's|/record-write.sh\([" ]*\) written|/record-write.sh\1 --format=codex written|g' \
		-e 's|/record-write.sh written|/record-write.sh --format=codex written|g' \
		-e 's|/lore-stats.sh\([" ]*\) export-summary|/lore-stats.sh\1 codex export-summary|g' \
		-e 's|/lore-stats.sh export-summary|/lore-stats.sh codex export-summary|g' \
		"$dst/SKILL.md" > "$dst/SKILL.md.new" && mv "$dst/SKILL.md.new" "$dst/SKILL.md"
	# Codex data-dir routing: without --format=codex the skill-run telemetry (record-write,
	# export-summary) would land in the Claude data dir while the gate writes to
	# ~/.codex/lore-data, splitting the funnel in half.
	if ! grep -q -- '--format=codex written' "$dst/SKILL.md" && grep -q 'record-write.sh' "$dst/SKILL.md"; then
		echo "⚠️ $dst: record-write rewrite did not take — check the SKILL text" >&2
	fi
done

# 2. Gate + path push + feedback/capture telemetry + metrics scripts
#    (record-feedback / record-write must sit next to the gate: the gate derives their
#    paths via $(dirname $0))
mkdir -p "$SCRIPTS_DST"
cp "$PLUGIN_DIR/scripts/memorize-gate.sh" "$PLUGIN_DIR/scripts/record-feedback.sh" \
	"$PLUGIN_DIR/scripts/record-write.sh" "$PLUGIN_DIR/scripts/push-knowledge.sh" \
	"$PLUGIN_DIR/scripts/session-start.sh" "$PLUGIN_DIR/scripts/lore-stats.sh" \
	"$PLUGIN_DIR/scripts/gen-knowledge-index.mjs" "$SCRIPTS_DST/"
chmod +x "$SCRIPTS_DST"/*.sh

# 3. Merge ~/.codex/hooks.json (existing hooks preserved, idempotent)
python3 - "$HOOKS" "$SCRIPTS_DST" <<'PY'
import json, os, sys
hp, scripts = sys.argv[1], sys.argv[2]
d = json.load(open(hp)) if os.path.exists(hp) else {}
hooks = d.setdefault("hooks", {})
# Same rule as uninstall: identify our own groups by the lore scripts dir inside the hook
# command, so an upgrade never drops a foreign group that happens to contain "lore".
def is_lore_group(g):
    return any(scripts in (h.get("command") or "") for h in g.get("hooks", []) if isinstance(h, dict))
def add(event, script, arg, matcher="*"):
    arr = hooks.setdefault(event, [])
    hooks[event] = [g for g in arr if not is_lore_group(g)]  # drop our previous version (upgrade)
    arr = hooks[event]
    arr.append({"matcher": matcher, "hooks": [{"type": "command", "command": f'"{scripts}/{script}" {arg}', "timeout": 15}]})
add("SessionStart", "session-start.sh", "codex")
add("Stop", "memorize-gate.sh", "codex")
add("PostToolUse", "push-knowledge.sh", "codex", matcher="apply_patch|Edit|Write")
os.makedirs(os.path.dirname(hp), exist_ok=True)
tmp = hp + ".tmp"
json.dump(d, open(tmp, "w"), ensure_ascii=False, indent=2)
os.replace(tmp, hp)
PY

echo "✓ lore installed for Codex:"
echo "  skills → $SKILLS_DST/{lore-memorize,lore-init,lore-knowledge-consolidate,lore-resolve-merge,lore-set-language}"
echo "  scripts → $SCRIPTS_DST"
echo "  hooks → $HOOKS (SessionStart + Stop gate + PostToolUse path push, codex mode)"
echo
echo "Next steps:"
echo "  1. Run /hooks in codex and trust the new hooks (unmanaged hooks need a one-time review)"
echo "  2. Run /skills and confirm the lore-* skills are discovered"
echo "  3. Restart codex or open a new session"
