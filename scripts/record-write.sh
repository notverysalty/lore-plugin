#!/bin/bash
# lore capture-result telemetry: invoked by the main session (LLM) after the gate
#   fires, recording the evaluation outcome — written = actually wrote/updated a
#   knowledge file (once per file) / nothing_to_save = evaluated, nothing qualified
#   (a legitimate and encouraged outcome).
#   Upgrades gate_fire's fire-COUNT into a fire→capture conversion funnel (consumed
#   by /lore:stats): without it, how many fires led to knowledge and how many were
#   ignored is a black box.
# Usage: record-write.sh [--format=codex] <written|nothing_to_save> [<filename.md>|<repo-dir:filename.md>] [<session_id>]
#   written requires the file argument; cross-repo writes (memorize step 4) use
#   repo-dir-name:filename.md to tag the owning repo.
# Principle: any anomaly exits silently (exit 0); never interrupt the main session.
set -u

command -v jq >/dev/null 2>&1 || exit 0

FORMAT=claude
case "${1:-}" in codex | --codex | --format=codex) FORMAT=codex && shift ;; esac

verdict="${1:-}"
file="${2:-}"
sid="${3:-unknown}"

# Only the two legal outcomes; anything else (incl. LLM typos) is dropped silently
case "$verdict" in
	written) [ -n "$file" ] || exit 0 ;;
	nothing_to_save) file="" ;;
	*) exit 0 ;;
esac

if [ "$FORMAT" = codex ]; then
	data_dir="${LORE_DATA_DIR:-$HOME/.codex/lore-data}"
else
	# Same as gate/track-load: stable dir survives uninstall/reinstall
	# (LORE_DATA_DIR is for tests)
	data_dir="${LORE_DATA_DIR:-$HOME/.claude/plugins/data/lore}"
fi
mkdir -p "$data_dir" 2>/dev/null || exit 0

# file may carry a repo-dir: prefix (cross-repo write); split out kb_repo = owning
# repo, aligned with kb_load's kb_repo for full-funnel joins
repo="$(basename "$(pwd 2>/dev/null)" 2>/dev/null)"
kb_repo="$repo"
case "$file" in
	*:*)
		kb_repo="${file%%:*}"
		file="${file#*:}"
		;;
esac

# jq --arg serialization: file/sid/repo containing quotes, backslashes, or control
# characters would corrupt the JSONL line under printf interpolation
jq -nc --arg repo "$repo" --arg kb "$kb_repo" --arg sid "$sid" --arg f "$file" --arg v "$verdict" \
	--arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" \
	'{event:"kb_write", repo:$repo, kb_repo:$kb, session:$sid, file:$f, verdict:$v, ts:$ts}' \
	>> "$data_dir/metrics.jsonl" 2>/dev/null
exit 0
