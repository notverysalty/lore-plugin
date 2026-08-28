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
exit 0
