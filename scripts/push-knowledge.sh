#!/bin/bash
# lore PostToolUse path push: when an edit hits a knowledge anchor path, inject
# that knowledge's read pointer into the next turn's context.
# On Claude Code, native path-scoped rules (.claude/rules/knowledge/) do this job
# and this script is unnecessary; Codex has no rules mechanism, so this script
# reuses the very same rules artifacts as the path→knowledge map (single source
# of truth, maintained by gen-knowledge-index.mjs) and matches/injects on
# PostToolUse(apply_patch|Edit|Write).
# Timing difference: Claude rules inject BEFORE touching a matched file; this
# hook injects AFTER the edit lands, effective next turn.
# Principle: any anomaly exits silently (exit 0); never block the session.
set -u

FORMAT=claude
case "${1:-}" in codex | --codex | --format=codex) FORMAT=codex ;; esac

input=$(cat 2>/dev/null) || exit 0
command -v jq >/dev/null 2>&1 || exit 0

cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
{ [ -z "$cwd" ] || [ -z "$sid" ]; } && exit 0

# Opt-in: no rules artifacts (repo not onboarded, or generator never ran) → total silence.
# cwd may be a SUBDIRECTORY of the repo, so walk up to the nearest ancestor that has the
# rules dir (the gate hooks do the same) — otherwise path pushing silently never fires.
root=""
probe="$cwd"
while [ -n "$probe" ] && [ "$probe" != "/" ]; do
	if [ -d "$probe/.claude/rules/knowledge" ]; then
		root="$probe"
		break
	fi
	probe=$(dirname "$probe")
done
[ -n "$root" ] || exit 0
rules_dir="$root/.claude/rules/knowledge"

# File paths touched by this edit: structured fields (Edit/Write shapes) + the
# "File:" lines of apply_patch patch text
paths=$(printf '%s' "$input" | jq -r '
	([.tool_input.file_path?, .tool_input.path?] | map(select(type=="string")))
	+ ([.tool_input.command?, .tool_input.patch?, .tool_input.input?]
		| map(select(type=="string")) | join("\n")
		| [scan("\\*\\*\\* (?:Update|Add|Delete) File: (.+)")] | map(.[0]))
	| .[] | select(length > 0)' 2>/dev/null | sort -u)
[ -z "$paths" ] && exit 0

if [ "$FORMAT" = codex ]; then
	data_dir="${LORE_DATA_DIR:-$HOME/.codex/lore-data}"
else
	data_dir="${LORE_DATA_DIR:-$HOME/.claude/plugins/data/lore}"
fi
mkdir -p "$data_dir/sessions" 2>/dev/null || exit 0
pushed="$data_dir/sessions/$sid.pushed"
repo=$(basename "$root")

hints=""
for rule in "$rules_dir"/*.md; do
	[ -f "$rule" ] || continue
	rkey="$repo:$(basename "$rule")"
	grep -qxF "$rkey" "$pushed" 2>/dev/null && continue   # per-session dedupe: each entry pushed at most once per session
	# paths array in the frontmatter (`  - "glob"` lines emitted by gen; same-PR
	# maintained, format is stable)
	globs=$(awk '/^---$/{n++;next} n==1 && /^  - /{gsub(/^  - |"/,"");print} n>=2{exit}' "$rule" 2>/dev/null)
	[ -z "$globs" ] && continue
	hit=""
	while IFS= read -r p; do
		[ -z "$p" ] && continue
		rel="${p#"$root"/}"
		# Split $globs on newlines only: default word splitting would break anchor paths
		# that legitimately contain spaces, so their knowledge would never be pushed.
		oldifs=$IFS
		IFS='
'
		for g in $globs; do
			# case's * crosses /; folding `**` into `*` yields gen's anchor
			# semantics (a directory anchor dir/** covers the whole subtree)
			case "$rel" in ${g//\*\*/*}) hit=1; break ;; esac
		done
		IFS=$oldifs
		[ -n "$hit" ] && break
	done <<-EOF
	$paths
	EOF
	[ -z "$hit" ] && continue
	hint=$(grep -m1 '^>' "$rule" 2>/dev/null)   # first quoted line of the rule = "read docs/ai-knowledge/x.md first (when to read)"
	[ -z "$hint" ] && continue
	hints="$hints$hint
"
	printf '%s\n' "$rkey" >> "$pushed" 2>/dev/null
	# Record the load: Codex has no InstructionsLoaded equivalent, so without this line the
	# runtime produces zero kb_load events and every downstream metric (feedback prompts,
	# never-loaded, team rollups) is systematically blind on Codex. Rule filename = knowledge
	# filename, so the key matches track-load's.
	jq -nc --arg repo "$repo" --arg f "$(basename "$rule")" --arg sid "$sid" \
		--arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" \
		'{event:"kb_load", repo:$repo, kb_repo:$repo, file:$f, reason:"path_push", session:$sid, ts:$ts}' \
		>> "$data_dir/metrics.jsonl" 2>/dev/null
done

[ -z "$hints" ] && exit 0
ctx="$hints> Knowledge is a lead, not the source of truth — verify against the code via the file's anchors before key decisions; when it contradicts the code, the code wins and the knowledge file gets fixed."
jq -nc --arg ctx "$ctx" '{hookSpecificOutput:{hookEventName:"PostToolUse", additionalContext:$ctx}}' 2>/dev/null
exit 0
