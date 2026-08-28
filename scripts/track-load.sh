#!/bin/bash
# lore: InstructionsLoaded telemetry — record lore knowledge files being loaded
# into context (read-rate metric).
# Claude Code-specific hook (Codex has no equivalent); async, observe-only,
# never blocks. Any anomaly exits silently.
set -u

input=$(cat 2>/dev/null) || exit 0
command -v jq >/dev/null 2>&1 || exit 0

fp=$(printf '%s' "$input" | jq -r '.file_path // empty' 2>/dev/null)
# Only lore knowledge files (docs/ai-knowledge/ or .claude/rules/knowledge/); ignore other loads
case "$fp" in
	*/docs/ai-knowledge/*) ;;
	*/.claude/rules/knowledge/*) ;;
	*) exit 0 ;;
esac
# Write-gate policy files (generator-emitted AGENTS.md/CLAUDE.md) are instructions,
# not knowledge content — skip so they don't inflate read metrics.
case "$(basename "$fp")" in
	AGENTS.md | CLAUDE.md) exit 0 ;;
esac

sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
reason=$(printf '%s' "$input" | jq -r '.load_reason // empty' 2>/dev/null)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)

# kb_repo = the repo the knowledge file actually belongs to (the directory above
# docs/ai-knowledge or rules/knowledge in file_path). repo (= session cwd) differs
# from the owning repo in umbrella-dir / cross-repo sessions; per-file aggregation
# must use kb_repo or every repo's INDEX.md/contract.md collapses into one key.
kb_root="${fp%/docs/ai-knowledge/*}"
[ "$kb_root" = "$fp" ] && kb_root="${fp%/.claude/rules/knowledge/*}"
kb_repo=$(basename "$kb_root" 2>/dev/null)

# Not CLAUDE_PLUGIN_DATA: deleted on uninstall, which loses metrics; use a stable
# dir (LORE_DATA_DIR is for tests)
data_dir="${LORE_DATA_DIR:-$HOME/.claude/plugins/data/lore}"
mkdir -p "$data_dir" 2>/dev/null || exit 0

# jq --arg serialization: paths/repo names containing quotes, backslashes, or
# control characters would corrupt the JSONL line under printf interpolation
jq -nc --arg repo "$(basename "$cwd")" --arg kb "$kb_repo" --arg f "$(basename "$fp")" \
	--arg r "$reason" --arg sid "$sid" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" \
	'{event:"kb_load", repo:$repo, kb_repo:$kb, file:$f, reason:$r, session:$sid, ts:$ts}' \
	>> "$data_dir/metrics.jsonl" 2>/dev/null
exit 0
