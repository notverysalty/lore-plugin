#!/bin/bash
# lore: Stop hook — drop this session's knowledge write grant.
#
# The grant is issued by knowledge-write-gate.sh when a lore skill is invoked
# and MUST NOT outlive the assistant turn that opened it: a marker that survives
# the turn means one throwaway `lore:memorize` call buys unlimited later hand
# edits, which is the bypass this design exists to close.
#
# Registered as its own Stop hook rather than folded into memorize-gate.sh:
# that script early-exits in many situations (stop_hook_active, subagent, repo
# without docs/ai-knowledge/, missing git), and cleanup must run unconditionally.
#
# Also sweeps grants older than a day so an interrupted session cannot leave a
# usable credential behind. Always exits 0 — cleanup must never block a turn.
set -u

input=$(cat 2>/dev/null) || exit 0
command -v jq >/dev/null 2>&1 || exit 0

session=$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null)
data_dir="${LORE_DATA_DIR:-$HOME/.claude/plugins/data/lore}"
grant_dir="$data_dir/write-grant"

[ -d "$grant_dir" ] || exit 0
[ -n "$session" ] && rm -f "$grant_dir/$session" 2>/dev/null

# Stale sweep (crashed / force-quit sessions).
find "$grant_dir" -type f -mtime +1 -delete 2>/dev/null

exit 0
