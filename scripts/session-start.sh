#!/bin/bash
# lore: record the session's starting HEAD, the baseline the Stop gate diffs
# against for "cumulative changes".
# Cross-runtime: defaults to Claude Code; pass codex / --format=codex for the
# Codex-specific state dir.
# Principle: any anomaly exits silently (exit 0); never affect session startup.
set -u

FORMAT=claude
case "${1:-}" in codex | --codex | --format=codex) FORMAT=codex ;; esac

input=$(cat 2>/dev/null) || exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
source=$(printf '%s' "$input" | jq -r '.source // empty' 2>/dev/null)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
{ [ -z "$sid" ] || [ -z "$cwd" ]; } && exit 0

# Opt-in: repos without a knowledge base leave no trace. cwd may be a SUBDIRECTORY of the
# repo, so walk up to the nearest ancestor holding the knowledge dir (the Stop gate does the
# same) — otherwise the baseline is never recorded for that session.
root=""
probe="$cwd"
while [ -n "$probe" ] && [ "$probe" != "/" ]; do
	if [ -d "$probe/docs/ai-knowledge" ]; then
		root="$probe"
		break
	fi
	probe=$(dirname "$probe")
done
[ -n "$root" ] || exit 0

if [ "$FORMAT" = codex ]; then
	data_dir="${LORE_DATA_DIR:-$HOME/.codex/lore-data}"
else
	# Not CLAUDE_PLUGIN_DATA: deleted on uninstall, which loses state; use a
	# stable dir (LORE_DATA_DIR is for tests)
	data_dir="${LORE_DATA_DIR:-$HOME/.claude/plugins/data/lore}"
fi
mkdir -p "$data_dir/sessions" 2>/dev/null || exit 0

head_sha=$(git -C "$root" --no-optional-locks rev-parse HEAD 2>/dev/null) || exit 0
# Never overwrite an existing baseline (resuming a session keeps its original start)
[ -f "$data_dir/sessions/$sid.head" ] || printf '%s' "$head_sha" > "$data_dir/sessions/$sid.head" 2>/dev/null

# Post-compaction nudge: SessionStart also fires after the runtime compacts the context
# (source=compact). Business facts learned early in a long session may no longer be in
# context by then, and the Stop gate can only judge what survives — so ask for a capture
# now instead of at wrap-up. Recorded as an event so stats can measure how often sessions
# compact before they end (the suspected source of a share of "nothing to save").
if [ "$source" = compact ]; then
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	jq -nc --arg repo "$(basename "$root")" --arg sid "$sid" --arg ts "$ts" \
		'{event: "compact", repo: $repo, session: $sid, ts: $ts}' >> "$data_dir/metrics.jsonl" 2>/dev/null
	nudge="[lore] Context was just compacted in a repo with a knowledge base (docs/ai-knowledge/). Business facts learned earlier in this session — facts you cannot derive from the code: implicit rules, cross-repo conventions, pitfalls with their causes, anti-knowledge — may no longer be in context, and the Stop gate will only see what survives. If any such fact was learned, capture it now with lore:memorize instead of waiting for wrap-up; if none, continue normally."
	jq -nc --arg ctx "$nudge" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
fi
exit 0
