#!/bin/bash
# lore doctor: is the engine actually wired up on this machine, and is this repo healthy?
# Every lore hook fails OPEN by design (a broken hook must never brick a session), which
# means a broken channel is silent — knowledge quietly stops being pushed, captured, or
# measured. This script makes that visible: dependency and layout checks, per-channel
# liveness from the local metrics, DRY RUNS of the write gate / Stop gate / path push with
# an isolated data dir, and the current repo's --check / scale status.
# Usage: bash lore-doctor.sh [codex] [repo-root]     exit 0 = no problems (warnings allowed)
set -u

FORMAT=claude
ROOT=""
for a in "$@"; do
	case "$a" in
		codex | --codex | --format=codex) FORMAT=codex ;;
		--*) ;;
		*) ROOT="$a" ;;
	esac
done
HERE=$(cd "$(dirname "$0")" && pwd)
ok=0 warn=0 bad=0
pass() { echo "✔ $1"; ok=$((ok + 1)); }
warnf() { echo "⚠ $1"; warn=$((warn + 1)); }
fail() { echo "✖ $1"; bad=$((bad + 1)); }
T=$(mktemp -d /tmp/lore-doctor.XXXXXX)
trap 'rm -rf "$T"' EXIT

echo "== lore doctor ($FORMAT) =="

# 1. dependencies
for c in jq git node; do
	command -v "$c" >/dev/null 2>&1 && pass "dependency: $c" || fail "dependency missing: $c"
done
nv=$(node -v 2>/dev/null | sed 's/^v//; s/\..*//')
[ "${nv:-0}" -ge 18 ] && pass "node >= 18 ($(node -v 2>/dev/null))" || fail "node >= 18 required (found: $(node -v 2>/dev/null || echo none))"

# 2. engine layout
missing=0
for f in memorize-gate.sh session-start.sh track-load.sh record-feedback.sh record-write.sh knowledge-write-gate.sh clear-write-grant.sh push-knowledge.sh lore-stats.sh gen-knowledge-index.mjs; do
	if [ -f "$HERE/$f" ]; then
		case "$f" in *.sh) [ -x "$HERE/$f" ] || warnf "not executable: $f (call it via bash explicitly)" ;; esac
	else
		fail "engine script missing: $f"; missing=1
	fi
done
[ "$missing" -eq 0 ] && pass "engine scripts present: $HERE"

# 3. hook registration
if [ "$FORMAT" = claude ]; then
	hj="$HERE/../hooks/hooks.json"
	if [ -f "$hj" ]; then
		for ev in PreToolUse PostToolUse SessionStart Stop InstructionsLoaded; do
			jq -e --arg e "$ev" '.hooks[$e] | length > 0' "$hj" >/dev/null 2>&1 && pass "hook registered: $ev" || fail "hook missing in hooks.json: $ev"
		done
	else
		fail "hooks/hooks.json not found next to scripts/ (plugin layout broken?)"
	fi
else
	hj="$HOME/.codex/hooks.json"
	if [ -f "$hj" ]; then
		for ev in SessionStart Stop PostToolUse; do
			jq -e --arg e "$ev" --arg s "$HERE" '[.hooks[$e][]?.hooks[]?.command | select(contains($s))] | length > 0' "$hj" >/dev/null 2>&1 \
				&& pass "codex hook wired: $ev" || fail "codex hook not wired to $HERE: $ev (rerun codex/install.sh, then /hooks to trust)"
		done
	else
		fail "~/.codex/hooks.json missing — run codex/install.sh"
	fi
fi

# 4. data dir
if [ "$FORMAT" = codex ]; then dd="${LORE_DATA_DIR:-$HOME/.codex/lore-data}"; else dd="${LORE_DATA_DIR:-$HOME/.claude/plugins/data/lore}"; fi
if mkdir -p "$dd" 2>/dev/null && [ -w "$dd" ]; then pass "data dir writable: $dd"; else fail "data dir not writable: $dd"; fi

# 5. channel liveness (from the real metrics stream)
m="$dd/metrics.jsonl"
if [ -f "$m" ]; then
	for ev in gate_fire kb_load kb_feedback kb_write; do
		last=$(jq -r --arg e "$ev" 'select(.event == $e) | .ts' "$m" 2>/dev/null | sort | tail -1)
		if [ -n "$last" ]; then pass "channel $ev: last event ${last%%T*}"; else warnf "channel $ev: never recorded (hook not firing, or no qualifying session yet)"; fi
	done
else
	warnf "no metrics yet at $m — run a session in an onboarded repo, then re-check"
fi

# 6. dry run: write gate (Claude Code channel) — grant issuance, engine-path injection, artifact denial
if [ "$FORMAT" = claude ]; then
	out=$(printf '{"tool_name":"Skill","tool_input":{"skill":"lore:memorize"},"session_id":"doctor"}' | LORE_DATA_DIR="$T/d" bash "$HERE/knowledge-write-gate.sh" 2>/dev/null)
	if [ -f "$T/d/write-grant/doctor" ] && printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | startswith("lore engine scripts: ")' >/dev/null 2>&1; then
		pass "write gate: grant issued + engine path injected on skill invocation"
	else
		fail "write gate dry run: grant/injection did not happen"
	fi
	rc=$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s"},"session_id":"nogrant","cwd":"%s"}' "$T/x/docs/ai-knowledge/INDEX.md" "$T/x" | LORE_DATA_DIR="$T/d" bash "$HERE/knowledge-write-gate.sh" >/dev/null 2>&1; echo $?)
	[ "$rc" = 2 ] && pass "write gate: generated artifact denied" || fail "write gate did not deny an artifact write (exit $rc)"
fi

# 7. dry run: Stop gate on a temporary onboarded repo
mkdir -p "$T/r/docs/ai-knowledge"
git -C "$T/r" init -q 2>/dev/null && git -C "$T/r" -c user.email=d@example.com -c user.name=d commit -q --allow-empty -m init 2>/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do printf '{"type":"user","message":"x"}\n' >> "$T/tr.jsonl"; done
gate_arg=""; [ "$FORMAT" = codex ] && gate_arg=codex
gj=$(printf '{"session_id":"doc","cwd":"%s","transcript_path":"%s"}' "$T/r" "$T/tr.jsonl" | LORE_DATA_DIR="$T/d" bash "$HERE/memorize-gate.sh" $gate_arg 2>/dev/null)
printf '%s' "$gj" | jq -e '.decision == "block"' >/dev/null 2>&1 && pass "stop gate: emits valid decision:block" || fail "stop gate dry run produced no valid continuation JSON"

# 8. dry run: path push
mkdir -p "$T/r/.claude/rules/knowledge"
printf -- '---\npaths:\n  - "src/**"\n---\n\n> Knowledge exists for this area: read docs/ai-knowledge/x.md first (t).\n' > "$T/r/.claude/rules/knowledge/x.md"
pj=$(printf '{"session_id":"doc2","cwd":"%s","tool_input":{"file_path":"%s"}}' "$T/r" "$T/r/src/a.ts" | LORE_DATA_DIR="$T/d" bash "$HERE/push-knowledge.sh" $gate_arg 2>/dev/null)
printf '%s' "$pj" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1 && pass "path push: emits valid additionalContext" || fail "path push dry run failed"

# 9. current repo
probe="${ROOT:-$PWD}"
repo=""
while [ -n "$probe" ] && [ "$probe" != "/" ]; do
	[ -d "$probe/docs/ai-knowledge" ] && { repo="$probe"; break; }
	probe=$(dirname "$probe")
done
if [ -n "$repo" ]; then
	pass "repo onboarded: $repo"
	if node "$HERE/gen-knowledge-index.mjs" "$repo" --check > "$T/check.log" 2>&1; then
		hints=$(grep -c '^\[lint\]' "$T/check.log")
		pass "gen --check: clean${hints:+ ($hints lint hint(s) — see lore:stats polish prescriptions)}"
		[ "${hints:-0}" -eq 0 ] && true
	else
		fail "gen --check reports problems/drift:"
		sed 's/^/    /' "$T/check.log" | head -8
	fi
	n=$(ls "$repo"/docs/ai-knowledge/*.md 2>/dev/null | grep -v -e INDEX.md -e AGENTS.md -e CLAUDE.md | wc -l | tr -d ' ')
	thr=$(jq -r '.indexGroupThreshold // 30' "$repo/docs/ai-knowledge/lore.json" 2>/dev/null); thr=${thr:-30}
	if [ "$n" -gt "$thr" ]; then pass "scale: $n entries — index runs in grouped mode (threshold $thr)"
	elif [ "$n" -gt $((thr * 8 / 10)) ]; then warnf "scale: $n entries, approaching the $thr-entry grouping threshold (lore.json indexMode/indexGroupThreshold to tune)"
	else pass "scale: $n entries (flat index)"; fi
	if [ -f "$repo/docs/ai-knowledge/lore.json" ]; then
		jq -e . "$repo/docs/ai-knowledge/lore.json" >/dev/null 2>&1 && pass "lore.json valid (language: $(jq -r '.language // "en"' "$repo/docs/ai-knowledge/lore.json"))" || fail "lore.json is not valid JSON"
	fi
else
	warnf "no onboarded repo at or above ${ROOT:-$PWD} (run lore:init to onboard one)"
fi

echo
echo "== $ok ok, $warn warning(s), $bad problem(s) =="
[ "$bad" -eq 0 ]
