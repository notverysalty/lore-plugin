#!/bin/bash
# lore knowledge feedback: invoked by the main session (LLM) at gate wrap-up to
#   record whether a loaded knowledge file was actually used / loaded but unused /
#   contradicts the code (likely stale) — upgrading load-COUNT metrics into
#   load-effectiveness + silent-rot candidates (consumed by /lore:stats and the
#   monthly knowledge-consolidate).
# Called by the LLM (not a hook): $CLAUDE_PLUGIN_DATA is usually absent at runtime,
#   so reuse lore-stats' directory discovery (glob existing lore* dirs, fallback
#   otherwise) to aggregate into the same metrics file as gate/track-load.
# Usage: record-feedback.sh [--format=codex] <used|ignored|contradicted> <filename.md> [<session_id>]
# Principle: any anomaly exits silently (exit 0); never interrupt the main session.
set -u

command -v jq >/dev/null 2>&1 || exit 0

FORMAT=claude
case "${1:-}" in codex | --codex | --format=codex) FORMAT=codex && shift ;; esac

verdict="${1:-}"
file="${2:-}"
sid="${3:-unknown}"

# Only the three legal verdicts; anything else (incl. LLM typos) is dropped silently
case "$verdict" in used | ignored | contradicted) ;; *) exit 0 ;; esac
[ -n "$file" ] || exit 0

if [ "$FORMAT" = codex ]; then
	data_dir="${LORE_DATA_DIR:-$HOME/.codex/lore-data}"
else
	# Same as lore-stats: outside hook context $CLAUDE_PLUGIN_DATA is untrustworthy;
	# glob existing lore* data dirs. LORE_DATA_DIR is for tests (matches
	# gate/track-load/record-write).
	data_dir="${LORE_DATA_DIR:-}"
	if [ -z "$data_dir" ]; then
		for d in "$HOME"/.claude/plugins/data/lore*; do
			[ -d "$d" ] && { data_dir="$d"; break; }
		done
		data_dir="${data_dir:-$HOME/.claude/plugins/data/lore}"
	fi
fi
mkdir -p "$data_dir" 2>/dev/null || exit 0

# jq --arg serialization: file/sid come from the LLM; quotes, backslashes, or
# control characters would corrupt the JSONL line under printf interpolation
jq -nc --arg repo "$(basename "$(pwd 2>/dev/null)" 2>/dev/null)" --arg sid "$sid" --arg f "$file" --arg v "$verdict" \
	--arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" \
	'{event:"kb_feedback", repo:$repo, session:$sid, file:$f, verdict:$v, ts:$ts}' \
	>> "$data_dir/metrics.jsonl" 2>/dev/null
exit 0
