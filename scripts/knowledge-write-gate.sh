#!/bin/bash
# lore: write gate for the knowledge dirs (docs/ai-knowledge/,
# .claude/rules/knowledge/). Prompt-level policy (the generated AGENTS/CLAUDE gate files)
# has been bypassed in practice — an agent hand-edited knowledge files during an
# incident fix and skipped frontmatter/regen; the reviewer caught it only
# post-hoc. This hook enforces the policy for every Claude Code session that has
# the lore plugin, regardless of cwd/worktree.
#
# WHAT THIS GUARANTEES (and what it does not) — read before changing:
#   Scope honesty: the grant is keyed by session and cleared at Stop; a turn that never
#   reaches Stop (interrupt, API failure) leaves it alive until the TTL expires — within
#   that window the same session (whose context still holds the skill instructions) could
#   write again. That is a bounded softening of "turn-scoped", not a bypass.
#   The agent owns a Bash tool, so ANY filesystem-based credential can be forged
#   with one `touch`. Unforgeable authorization is therefore impossible at this
#   layer, and the gate does not pretend otherwise. What it does guarantee is:
#   **a knowledge file cannot be written unless a lore skill was invoked in the
#   current assistant turn** — which means the skill's instructions (rubric,
#   dedupe, frontmatter spec, regen step) are necessarily in context at the
#   moment of writing. That is exactly what was missing in the incident.
#   Deliberate forgery is out of scope by design and is left to CI + code review.
#
# Mechanism (three hook events, see hooks/hooks.json):
#   PostToolUse  + Skill=lore:*  -> issue a turn-scoped grant (this hook is the
#                                   ONLY issuer; there is no agent-callable
#                                   grant command to copy-paste)
#   PreToolUse   + file tools    -> knowledge paths need a live grant with uses
#                                   left; each write consumes one use
#   Stop                         -> clear-write-grant.sh drops the grant, so the
#                                   window dies with the turn that opened it
#                                   (a marker that outlives the skill flow would
#                                   only add one throwaway Skill call)
#   Generated artifacts (INDEX/AGENTS/CLAUDE/rules) are denied unconditionally —
#   rerun gen-knowledge-index.mjs instead.
#
# Paths are normalized before classification (.., ., //, relative-to-cwd, case
# folding) so non-canonical spellings cannot dodge the artifact rules.
# Protected-tree paths that cannot be resolved fail CLOSED.
#
# Other boundaries (deliberate):
#   - writes via Bash (sed/heredoc) are NOT caught here — repo-side CI
#     (ci/knowledge-check.yml) backstops those, agents without this plugin, and
#     --no-verify commits
#   - fail-open on gate-internal breakage only (missing jq / unreadable input):
#     never brick editing because the gate itself broke
set -u

[ "${LORE_WRITE_GATE_DISABLE:-0}" = "1" ] && exit 0

input=$(cat 2>/dev/null) || exit 0
command -v jq >/dev/null 2>&1 || exit 0

tool=$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null) || exit 0
session=$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null)
data_dir="${LORE_DATA_DIR:-$HOME/.claude/plugins/data/lore}"
grant_dir="$data_dir/write-grant"
# Uses are bounded so one skill call cannot become an open-ended writing spree;
# memorize caps a PR at 2 knowledge files, consolidate/init touch more.
max_uses="${LORE_WRITE_GRANT_USES:-40}"
# Short TTL backstops turns that never reach Stop (interrupt / API failure): a leftover
# grant dies on its own within minutes instead of an hour.
ttl="${LORE_WRITE_GRANT_TTL:-600}"

# --- Skill branch (PostToolUse): issue the turn-scoped grant -----------------
if [ "$tool" = "Skill" ]; then
	skill=$(printf '%s' "$input" | jq -r '.tool_input.skill // ""' 2>/dev/null)
	case "$skill" in
		lore:memorize | lore:knowledge-consolidate | lore:resolve-merge | lore:init | lore:set-language | \
			lore-memorize | lore-knowledge-consolidate | lore-resolve-merge | lore-init | lore-set-language)
			[ -n "$session" ] || exit 0
			mkdir -p "$grant_dir" 2>/dev/null || exit 0
			printf 'skill=%s at=%s uses=%s\n' "$skill" "$(date +%s)" "$max_uses" \
				> "$grant_dir/$session" 2>/dev/null
			# Tell the model where the engine actually lives. SKILL.md text cannot carry an
			# absolute path (${CLAUDE_PLUGIN_ROOT} is NOT expanded in skill bodies — verified),
			# and letting the model guess picked the wrong copy on a machine with two lore
			# installs. This hook knows its own location, so it injects the truth at the exact
			# moment the skill starts. Skills refer to this line as <engine-scripts>.
			gate_dir=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
			[ -n "$gate_dir" ] && jq -nc --arg d "$gate_dir" \
				'{hookSpecificOutput:{hookEventName:"PostToolUse", additionalContext:("lore engine scripts: " + $d + " — use this absolute path for gen-knowledge-index.mjs / record-write.sh / record-feedback.sh / lore-stats.sh; do not guess or search for other copies.")}}' 2>/dev/null
			;;
	esac
	exit 0
fi

case "$tool" in
	Edit | Write | MultiEdit | NotebookEdit) ;;
	*) exit 0 ;;
esac

fp=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' 2>/dev/null) || exit 0
[ -n "$fp" ] || exit 0

# --- Normalization (classification must not trust raw path strings) ---
# Relative paths are joined onto the hook-provided cwd first.
case "$fp" in
	/*) ;;
	*)
		cwd=$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null)
		[ -n "$cwd" ] && fp="$cwd/$fp"
		;;
esac

normalize_path() {
	# Prefer python3: normpath + realpath of the nearest existing ancestor, so
	# dot-segments AND symlinked ancestor dirs both collapse. Falls back to a
	# pure awk segment-stack normalizer (// , /./ , /../) without python3.
	if command -v python3 >/dev/null 2>&1; then
		python3 - "$1" <<'PY' 2>/dev/null && return 0
import os, sys
p = os.path.normpath(sys.argv[1])
# Resolve the FINAL component too when it already exists (lexists covers symlinks): a
# symlink named like an ordinary knowledge file otherwise passes the "knowledge" check and
# the write lands on whatever it points at — e.g. INDEX.md. Only resolving the parent
# directory left that door open.
if os.path.lexists(p):
    print(os.path.realpath(p))
    sys.exit(0)
d, b = os.path.dirname(p), os.path.basename(p)
probe = d
while probe and probe != os.path.sep and not os.path.isdir(probe):
    probe = os.path.dirname(probe)
if probe and os.path.isdir(probe):
    resolved = os.path.realpath(probe)
    rest = os.path.relpath(d, probe)
    d = resolved if rest == "." else os.path.join(resolved, rest)
print(os.path.join(d, b))
PY
	fi
	printf '%s' "$1" | awk -F/ '{
		n = 0
		for (i = 1; i <= NF; i++) {
			seg = $i
			if (seg == "" || seg == ".") continue
			if (seg == "..") { if (n > 0) n--; continue }
			stack[++n] = seg
		}
		out = ""
		for (i = 1; i <= n; i++) out = out "/" stack[i]
		print (out == "" ? "/" : out)
	}'
}

norm=$(normalize_path "$fp")
if [ -z "$norm" ]; then
	# Normalization itself broke. Fail closed only when the raw string smells
	# like a protected tree; unrelated files must never be blocked by gate
	# breakage (fail-open philosophy).
	case "$fp" in
		*[Aa][Ii]-[Kk][Nn][Oo][Ww][Ll][Ee][Dd][Gg][Ee]*)
			echo "BLOCKED: un-normalizable path targeting the lore knowledge dir ($fp). Retry with a canonical absolute path." >&2
			exit 2
			;;
		*) exit 0 ;;
	esac
fi

# Classification is case-folded: these repos live on case-insensitive
# filesystems (macOS default), where Docs/AI-Knowledge/INDEX.md is the same file.
lower=$(printf '%s' "$norm" | tr '[:upper:]' '[:lower:]')

# Residual dot-segments after normalization = unclassifiable; fail closed for
# protected trees: `..` spellings are rejected explicitly.
case "$lower" in
	*ai-knowledge* | */rules/knowledge*)
		case "$lower" in
			*/../* | ../* | */.. | */./* | ./* | .)
				echo "BLOCKED: path contains unresolved . / .. segments and targets the lore knowledge dir ($fp). Retry with a canonical absolute path." >&2
				exit 2
				;;
		esac
		;;
esac

kind=""
case "$lower" in
	*/docs/ai-knowledge/index.md | */docs/ai-knowledge/agents.md | */docs/ai-knowledge/claude.md) kind="generated" ;;
	*/docs/ai-knowledge/.metrics/*) kind="generated" ;;   # per-user rollups: produced by lore-stats.sh export-summary only
	*/.claude/rules/knowledge/*) kind="generated" ;;
	*/docs/ai-knowledge/*) kind="knowledge" ;;
	*) exit 0 ;;
esac

self_dir=$(cd "$(dirname "$0")" && pwd)

if [ "$kind" = "generated" ]; then
	{
		echo "BLOCKED: lore generated artifacts must not be hand-edited ($fp)."
		echo "INDEX.md / AGENTS.md / CLAUDE.md / .claude/rules/knowledge/* are generator output:"
		echo "edit the knowledge files themselves, then run node $self_dir/gen-knowledge-index.mjs <repo-root> to rebuild."
		echo "(.metrics/*.json rollups are produced by: bash $self_dir/lore-stats.sh export-summary <repo-root>)"
	} >&2
	exit 2
fi

# --- Knowledge content: consume one use of the turn-scoped grant -------------
deny() {
	{
		echo "BLOCKED: docs/ai-knowledge/ is write-gated; do not hand-edit around the lore flows ($fp)."
		echo "Correct paths: new knowledge / corrections -> lore:memorize; governance -> lore:knowledge-consolidate;"
		echo "merge conflicts -> lore:resolve-merge; onboarding -> lore:init; language -> lore:set-language."
		echo "The grant is auto-issued when those skills are invoked — bounded uses, cleared at Stop; there is no manual grant command."
		echo "Full policy: the target repo's docs/ai-knowledge/AGENTS.md."
	} >&2
	exit 2
}

[ -n "$session" ] || deny
grant="$grant_dir/$session"
[ -f "$grant" ] || deny

# TTL is anchored on the recorded issue time, read from the grant's own `at=`
# field — NEVER on the file's mtime. Consuming a use rewrites the file, which
# necessarily bumps mtime; an earlier version tried to restore it with
# `touch -t $(date -r ...)`, but `-r` means "epoch -> format" only on BSD date
# (macOS). GNU date (Linux/CI) reads it as a FILE name, the command fails, the
# touch silently no-ops, and every write ends up renewing the window — the exact
# opposite of the promise, and invisible on a macOS-only test run.
now=$(date +%s)
issued=$(sed -n 's/.*at=\([0-9][0-9]*\).*/\1/p' "$grant" 2>/dev/null | head -1)
# A grant without a well-formed numeric issue time cannot be aged — fail closed.
case "$issued" in
	'' | *[!0-9]*) deny ;;
esac
age=$((now - issued))
{ [ "$age" -ge 0 ] && [ "$age" -lt "$ttl" ]; } || deny

uses=$(sed -n 's/.*uses=\([0-9][0-9]*\).*/\1/p' "$grant" 2>/dev/null | head -1)
[ -n "$uses" ] || uses=0
[ "$uses" -gt 0 ] || deny

# Consume one use, preserving the original issue time verbatim. mtime is now
# irrelevant to authorization (clear-write-grant.sh still uses it, but only to
# sweep abandoned files, where "roughly a day old" is good enough).
skill_of=$(sed -n 's/^skill=\([^ ]*\).*/\1/p' "$grant" 2>/dev/null | head -1)
printf 'skill=%s at=%s uses=%s\n' "${skill_of:-unknown}" "$issued" "$((uses - 1))" > "$grant" 2>/dev/null

exit 0
