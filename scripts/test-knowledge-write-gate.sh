#!/usr/bin/env bash
# Regression tests for knowledge-write-gate.sh + clear-write-grant.sh
# (bash 3.2 compatible, self-contained temp dirs, no git binary required).
# Usage: bash test-knowledge-write-gate.sh   expects all PASS, exit 0.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
GATE="$HERE/knowledge-write-gate.sh"
CLEAR="$HERE/clear-write-grant.sh"
T=$(mktemp -d /tmp/lore-gate-test.XXXXXX)
trap 'rm -rf "$T"' EXIT
fail=0

# Grant state lives under LORE_DATA_DIR (test-injectable, same convention as
# track-load.sh). SID identifies the simulated session/turn.
export LORE_DATA_DIR="$T/data"
SID="sess-test-1"
GRANT_FILE="$LORE_DATA_DIR/write-grant/$SID"

REPO="$T/repo"
mkdir -p "$REPO/.git" "$REPO/docs/ai-knowledge/subdir" "$REPO/.claude/rules/knowledge"
WT="$T/wt"
WT_GITDIR="$T/gitdirs/wt1"
mkdir -p "$WT" "$WT_GITDIR" "$WT/docs/ai-knowledge"
printf 'gitdir: %s\n' "$WT_GITDIR" > "$WT/.git"

payload() {
	printf '{"tool_name":"%s","tool_input":{"file_path":"%s"},"session_id":"%s","cwd":"%s"}' "$1" "$2" "$SID" "$REPO"
}
skill_payload() {
	printf '{"tool_name":"Skill","tool_input":{"skill":"%s"},"session_id":"%s"}' "$1" "$SID"
}
run_gate() {
	printf '%s' "$1" | bash "$GATE" >/dev/null 2>&1
	echo $?
}
check() {
	if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1 (expected exit $2, got $3)"; fail=1; fi
}
invoke_skill() {
	rc=$(run_gate "$(skill_payload "${1:-lore:memorize}")")
	[ "$rc" = "0" ] || { echo "FAIL setup: Skill payload should exit 0"; fail=1; }
}
end_turn() {
	printf '{"session_id":"%s"}' "$SID" | bash "$CLEAR" >/dev/null 2>&1
}

# ---- the grant is hook-issued only; nothing the agent can run creates it ----

# T1 cold: no skill invoked -> deny
rc=$(run_gate "$(payload Write "$REPO/docs/ai-knowledge/foo.md")")
check "T1 deny before any lore skill" 2 "$rc"

# T2 lore skill invoked in this turn -> allow
invoke_skill
rc=$(run_gate "$(payload Edit "$REPO/docs/ai-knowledge/foo.md")")
check "T2 allow after lore skill in same turn" 0 "$rc"

# T2b the Skill branch injects the engine-scripts path (SKILL bodies cannot expand
# ${CLAUDE_PLUGIN_ROOT} and models guess wrong with multiple installs) — output must be
# valid JSON whose additionalContext carries this script's own directory
out=$(printf '%s' "$(skill_payload 'lore:memorize')" | bash "$GATE" 2>/dev/null)
if printf '%s' "$out" | jq -e --arg d "$HERE" '.hookSpecificOutput.additionalContext | startswith("lore engine scripts: " + $d)' >/dev/null 2>&1; then
	echo "PASS T2b Skill branch injects the engine-scripts path"
else
	echo "FAIL T2b engine-path injection: $(printf '%s' "$out" | head -c 150)"; fail=1
fi

# T3 THE KEY BYPASS: skill was called earlier, turn ended, agent tries to
# hand-edit later -> deny. (Previously a session marker survived the turn, so one
# throwaway lore:memorize bought unlimited later edits.)
end_turn
rc=$(run_gate "$(payload Write "$REPO/docs/ai-knowledge/foo.md")")
check "T3 deny after the granting turn ended" 2 "$rc"

# T4 there is no agent-callable grant command shipped
if [ -e "$HERE/lore-write-grant.sh" ]; then
	echo "FAIL T4 an agent-callable grant script still exists"; fail=1
else
	echo "PASS T4 no agent-callable grant script shipped"
fi

# T5 non-lore skill must not issue a grant
end_turn
rc=$(run_gate "$(skill_payload 'other-plugin:some-skill')")
check "T5a non-lore Skill passes through" 0 "$rc"
rc=$(run_gate "$(payload Write "$REPO/docs/ai-knowledge/foo.md")")
check "T5b deny: non-lore skill issued no grant" 2 "$rc"

# T5c set-language is a granting skill too (it writes lore.json in the knowledge dir)
invoke_skill 'lore:set-language'
rc=$(run_gate "$(payload Write "$REPO/docs/ai-knowledge/lore.json")")
check "T5c allow lore.json write after lore:set-language" 0 "$rc"
end_turn

# T6 uses are bounded: a single skill call is not an open-ended spree
end_turn
rc=$(printf '%s' "$(skill_payload 'lore:memorize')" | LORE_WRITE_GRANT_USES=2 bash "$GATE" >/dev/null 2>&1; echo $?)
check "T6a skill issues a 2-use grant" 0 "$rc"
rc=$(run_gate "$(payload Write "$REPO/docs/ai-knowledge/a.md")")
check "T6b first write consumes a use" 0 "$rc"
rc=$(run_gate "$(payload Write "$REPO/docs/ai-knowledge/b.md")")
check "T6c second write consumes the last use" 0 "$rc"
rc=$(run_gate "$(payload Write "$REPO/docs/ai-knowledge/c.md")")
check "T6d third write denied (uses exhausted)" 2 "$rc"

# T7 expired grant -> deny
end_turn
invoke_skill
rc=$(printf '%s' "$(payload Write "$REPO/docs/ai-knowledge/foo.md")" | LORE_WRITE_GRANT_TTL=0 bash "$GATE" >/dev/null 2>&1; echo $?)
check "T7 deny when grant TTL forces expiry" 2 "$rc"

# T8 TTL anchors on the recorded issue time, not on the file's mtime.
# Only `at=` is aged back here and mtime is deliberately left fresh: an
# mtime-based implementation would still see a young file and allow.
end_turn
invoke_skill
age_grant() {
	# rewrite at=<old epoch> while leaving mtime at "now"
	sed 's/at=[0-9][0-9]*/at=1000000000/' "$GRANT_FILE" > "$GRANT_FILE.tmp" && mv "$GRANT_FILE.tmp" "$GRANT_FILE"
}
age_grant
rc=$(run_gate "$(payload Write "$REPO/docs/ai-knowledge/foo.md")")
check "T8 deny stale grant (old at=, fresh mtime)" 2 "$rc"

# T8b the TTL-renewal regression: write once successfully, then let the
# TTL pass — the consumed-and-rewritten grant must NOT have renewed itself.
# Catches the `touch -t $(date -r ...)` bug, which no-ops on GNU date and let
# every write bump mtime (invisible if TTL were read from mtime).
end_turn
invoke_skill
rc=$(run_gate "$(payload Write "$REPO/docs/ai-knowledge/first.md")")
check "T8b first write succeeds" 0 "$rc"
age_grant
rc=$(run_gate "$(payload Write "$REPO/docs/ai-knowledge/second.md")")
check "T8b second write denied after TTL despite prior write" 2 "$rc"

# ---- generated artifacts: denied even with a live grant ----
end_turn
invoke_skill
rc=$(run_gate "$(payload Edit "$REPO/docs/ai-knowledge/INDEX.md")")
check "T9 deny generated INDEX.md despite grant" 2 "$rc"
rc=$(run_gate "$(payload Write "$REPO/docs/ai-knowledge/AGENTS.md")")
check "T10 deny generated AGENTS.md despite grant" 2 "$rc"
rc=$(run_gate "$(payload Write "$REPO/.claude/rules/knowledge/foo.md")")
check "T11 deny generated rules despite grant" 2 "$rc"
rc=$(run_gate "$(payload Write "$REPO/docs/ai-knowledge/.metrics/alice.json")")
check "T11b deny hand-edit of metrics rollups despite grant" 2 "$rc"

# ---- path normalization ----
rc=$(run_gate "$(payload Edit "$REPO/docs/ai-knowledge/subdir/../INDEX.md")")
check "T12 deny ../ traversal to INDEX.md" 2 "$rc"
rc=$(run_gate "$(payload Edit "$REPO/docs//ai-knowledge/./AGENTS.md")")
check "T13 deny //+/./ spelling of AGENTS.md" 2 "$rc"
rc=$(run_gate "$(payload Edit "$REPO/docs/ai-knowledge/subdir/../foo.md")")
check "T14 allow normalized knowledge path with grant" 0 "$rc"
rc=$(run_gate "$(payload Write "docs/ai-knowledge/INDEX.md")")
check "T15 deny relative-path spelling of INDEX.md" 2 "$rc"
rc=$(run_gate "$(payload Write "$REPO/Docs/AI-Knowledge/index.MD")")
check "T16 deny case-variant spelling of INDEX.md" 2 "$rc"

# ---- worktree layout (grant is session-scoped, so it covers sibling repos) ----
rc=$(run_gate "$(payload Write "$WT/docs/ai-knowledge/bar.md")")
check "T17a allow worktree write within granting turn" 0 "$rc"
end_turn
rc=$(run_gate "$(payload Write "$WT/docs/ai-knowledge/bar.md")")
check "T17b deny worktree write after turn ended" 2 "$rc"

# ---- pass-throughs and escape hatch ----
invoke_skill
rc=$(run_gate "$(payload Write "$REPO/src/index.ts")")
check "T18 allow unrelated path" 0 "$rc"
rc=$(run_gate '{"tool_name":"Bash","tool_input":{"command":"echo hi"},"session_id":"sess-test-1"}')
check "T19 ignore non-file tools" 0 "$rc"
rc=$(printf '%s' "$(payload Write "$REPO/docs/ai-knowledge/INDEX.md")" | LORE_WRITE_GATE_DISABLE=1 bash "$GATE" >/dev/null 2>&1; echo $?)
check "T20 allow when explicitly disabled" 0 "$rc"

# T21 archive files are knowledge content too
end_turn
mkdir -p "$REPO/docs/ai-knowledge/archive"
rc=$(run_gate "$(payload Write "$REPO/docs/ai-knowledge/archive/old.md")")
check "T21 deny archive write without grant" 2 "$rc"

# T23b a symlink whose name looks like knowledge but points at a generated artifact must be
# denied: classification resolves the final component, not just the parent directory.
end_turn
invoke_skill
: > "$REPO/docs/ai-knowledge/INDEX.md"
ln -sf "$REPO/docs/ai-knowledge/INDEX.md" "$REPO/docs/ai-knowledge/sneaky.md"
rc=$(run_gate "$(payload Write "$REPO/docs/ai-knowledge/sneaky.md")")
check "T23b deny symlink pointing at a generated artifact" 2 "$rc"
rm -f "$REPO/docs/ai-knowledge/sneaky.md" "$REPO/docs/ai-knowledge/INDEX.md"
end_turn   # restore the "no live grant" precondition the following case depends on

# T22 NotebookEdit uses notebook_path
rc=$(printf '{"tool_name":"NotebookEdit","tool_input":{"notebook_path":"%s"},"session_id":"%s"}' "$REPO/docs/ai-knowledge/nb.ipynb" "$SID" | bash "$GATE" >/dev/null 2>&1; echo $?)
check "T22 deny NotebookEdit via notebook_path" 2 "$rc"

# T23 Stop-hook sweep removes stale grants from crashed sessions
mkdir -p "$LORE_DATA_DIR/write-grant"
printf 'skill=lore:memorize at=1 uses=40\n' > "$LORE_DATA_DIR/write-grant/other-session"
touch -t 202001010000 "$LORE_DATA_DIR/write-grant/other-session"
end_turn
if [ -f "$LORE_DATA_DIR/write-grant/other-session" ]; then
	echo "FAIL T23 stale grant from another session not swept"; fail=1
else
	echo "PASS T23 stale grant swept by Stop hook"
fi

exit $fail
