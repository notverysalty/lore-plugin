#!/usr/bin/env bash
# lore hook-output regression tests: the Stop gate and the path push must emit VALID JSON in
# both runtime formats, and the metrics report must survive a fresh install with no data.
# This suite exists because hand-built JSON silently broke once when prose inside the
# injected reason contained a double quote — every gate fire produced unparseable output,
# which no other test covered.
# Usage: bash test-hooks-output.sh   Expect all PASS, exit 0.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d /tmp/lore-hooks-test.XXXXXX)
trap 'rm -rf "$T"' EXIT
fail=0
export LORE_DATA_DIR="$T/data"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not available"; exit 0; }

REPO="$T/repo"
mkdir -p "$REPO/docs/ai-knowledge" "$REPO/src/deep/nested"
git -C "$REPO" init -q
git -C "$REPO" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
# enough real user turns to satisfy the gate's signal B
for _ in 1 2 3 4 5 6 7 8 9 10; do printf '{"type":"user","message":"hi"}\n' >> "$T/transcript.jsonl"; done

gate() {
	printf '{"session_id":"%s","cwd":"%s","transcript_path":"%s"}' "$1" "$2" "$T/transcript.jsonl" |
		bash "$HERE/memorize-gate.sh" ${3:-} 2>/dev/null
}

# T1 Claude Code format: valid JSON, decision=block, non-trivial reason
out=$(gate s1 "$REPO")
if printf '%s' "$out" | jq -e '.decision == "block" and (.reason | length > 100)' >/dev/null 2>&1; then
	echo "PASS T1 Stop gate emits valid Claude Code JSON"
else
	echo "FAIL T1 invalid gate JSON: $(printf '%s' "$out" | head -c 200)"; fail=1
fi

# T2 the reason must carry REAL newlines, not the literal two-character \n — the wrap-up card
# is unreadable otherwise
if printf '%s' "$out" | jq -e '.reason | contains("\n")' >/dev/null 2>&1 &&
	! printf '%s' "$out" | jq -e '.reason | contains("\\n")' >/dev/null 2>&1; then
	echo "PASS T2 reason contains real newlines, no literal backslash-n"
else
	echo "FAIL T2 newline handling in reason"; fail=1
fi

# T3 Codex mode: same continuation shape as Claude Code ({"decision":"block"} — per the
# Codex hooks docs the older {"continue":false} means STOP, not continue), with the
# Codex-specific skill name substituted into the reason
out=$(gate s2 "$REPO" codex)
if printf '%s' "$out" | jq -e '.decision == "block" and (.reason | contains("lore-memorize"))' >/dev/null 2>&1 &&
	! printf '%s' "$out" | jq -e 'has("continue")' >/dev/null 2>&1; then
	echo "PASS T3 Codex mode emits decision:block with lore-memorize naming"
else
	echo "FAIL T3 codex-mode gate JSON: $(printf '%s' "$out" | head -c 150)"; fail=1
fi

# T4 loaded-knowledge feedback block: filenames with a double quote must not break the JSON
# (the exact class of bug this suite was added for)
mkdir -p "$LORE_DATA_DIR"
jq -nc '{event:"kb_load", repo:"repo", kb_repo:"repo", file:"we\"ird.md", reason:"include", session:"s3", ts:"2026-01-01T00:00:00Z"}' >> "$LORE_DATA_DIR/metrics.jsonl"
out=$(gate s3 "$REPO")
if printf '%s' "$out" | jq -e '.reason | contains("we\"ird.md")' >/dev/null 2>&1; then
	echo "PASS T4 quote-containing knowledge filename survives JSON encoding"
else
	echo "FAIL T4 quoted filename broke the gate output"; fail=1
fi

# T5 the gate must fire from a SUBDIRECTORY of the repo (agents are often started in src/)
out=$(gate s4 "$REPO/src/deep/nested")
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
	echo "PASS T5 gate resolves the repo root from a subdirectory"
else
	echo "FAIL T5 gate silent when cwd is a subdirectory"; fail=1
fi

# T6 opt-out really is silent: a repo without docs/ai-knowledge/ produces no output at all
OTHER="$T/plain"
mkdir -p "$OTHER"
git -C "$OTHER" init -q
git -C "$OTHER" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
out=$(gate s5 "$OTHER")
if [ -z "$out" ]; then
	echo "PASS T6 non-onboarded repo stays silent"
else
	echo "FAIL T6 unexpected output for a non-onboarded repo"; fail=1
fi

# T7 path push emits valid JSON with additionalContext when an edit hits an anchor
mkdir -p "$REPO/.claude/rules/knowledge"
cat > "$REPO/.claude/rules/knowledge/demo.md" <<'EOF'
---
paths:
  - "src/**"
---

> Knowledge exists for this area: read docs/ai-knowledge/demo.md first (test entry).
EOF
out=$(printf '{"session_id":"p1","cwd":"%s","tool_input":{"file_path":"%s"}}' "$REPO" "$REPO/src/deep/nested/x.ts" |
	bash "$HERE/push-knowledge.sh" 2>/dev/null)
if printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | contains("docs/ai-knowledge/demo.md")' >/dev/null 2>&1; then
	echo "PASS T7 path push emits valid JSON for an anchored edit"
else
	echo "FAIL T7 push output: $(printf '%s' "$out" | head -c 200)"; fail=1
fi

# T8 anchor globs containing spaces still match (word splitting used to drop them)
cat > "$REPO/.claude/rules/knowledge/spaced.md" <<'EOF'
---
paths:
  - "src/my dir/**"
---

> Knowledge exists for this area: read docs/ai-knowledge/spaced.md first (spaced anchor).
EOF
mkdir -p "$REPO/src/my dir"
out=$(printf '{"session_id":"p2","cwd":"%s","tool_input":{"file_path":"%s"}}' "$REPO" "$REPO/src/my dir/y.ts" |
	bash "$HERE/push-knowledge.sh" 2>/dev/null)
if printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | contains("spaced.md")' >/dev/null 2>&1; then
	echo "PASS T8 anchor path containing a space still matches"
else
	echo "FAIL T8 spaced anchor did not match"; fail=1
fi

# T9 a fresh install (no metrics file) must still run and report the inventory, not bail out
FRESH="$T/fresh-data"
cat > "$REPO/docs/ai-knowledge/demo.md" <<'EOF'
---
name: demo
description: test entry
scope: repo
code-anchors: []
status: fact
provenance: test
env: all
promote: n/a
updated: 2026-01-01
---
body
EOF
out=$(cd "$REPO" && LORE_DATA_DIR="$FRESH" bash "$HERE/lore-stats.sh" codex 2>&1)
if printf '%s' "$out" | grep -q 'No event metrics yet' && printf '%s' "$out" | grep -q 'inventory'; then
	echo "PASS T9 stats runs the inventory scan with no metrics file"
else
	echo "FAIL T9 stats output on a fresh install: $(printf '%s' "$out" | head -c 200)"; fail=1
fi

# T10 export-summary distills the local stream into a committed per-user rollup:
# correct counts, no session ids, repo-scoped filtering
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
RB=$(basename "$REPO")
# t10.md is unique to this case: earlier cases (gate fires, path pushes) already wrote
# events for demo.md, so exact-count assertions must use an unpolluted key
for e in \
	"{\"event\":\"kb_load\",\"repo\":\"$RB\",\"kb_repo\":\"$RB\",\"file\":\"t10.md\",\"reason\":\"include\",\"session\":\"sx\",\"ts\":\"$NOW\"}" \
	"{\"event\":\"kb_load\",\"repo\":\"$RB\",\"kb_repo\":\"$RB\",\"file\":\"t10.md\",\"reason\":\"path_glob_match\",\"session\":\"sy\",\"ts\":\"$NOW\"}" \
	"{\"event\":\"kb_feedback\",\"repo\":\"$RB\",\"session\":\"sx\",\"file\":\"$RB:t10.md\",\"verdict\":\"used\",\"ts\":\"$NOW\"}" \
	"{\"event\":\"kb_feedback\",\"repo\":\"$RB\",\"session\":\"sy\",\"file\":\"$RB:t10.md\",\"verdict\":\"ignored\",\"ts\":\"$NOW\"}" \
	"{\"event\":\"kb_write\",\"repo\":\"$RB\",\"kb_repo\":\"$RB\",\"session\":\"sx\",\"file\":\"t10.md\",\"verdict\":\"written\",\"ts\":\"$NOW\"}" \
	"{\"event\":\"kb_load\",\"repo\":\"other\",\"kb_repo\":\"other\",\"file\":\"foreign.md\",\"reason\":\"include\",\"session\":\"sz\",\"ts\":\"$NOW\"}"; do
	printf '%s\n' "$e" >> "$LORE_DATA_DIR/metrics.jsonl"
done
# T10a team metrics are opt-in: without "teamMetrics": true in lore.json, export-summary must
# write nothing (not even the .metrics dir), say so, and still exit 0
out=$(cd "$T" && LORE_METRICS_USER=alice bash "$HERE/lore-stats.sh" export-summary "$REPO" 2>&1); rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q 'team metrics are off' && [ ! -e "$REPO/docs/ai-knowledge/.metrics" ]; then
	echo "PASS T10a export-summary without opt-in: nothing written, exit 0, explains how to opt in"
else
	echo "FAIL T10a rc=$rc exists=$([ -e "$REPO/docs/ai-knowledge/.metrics" ] && echo yes || echo no): $out"; fail=1
fi
printf '{"language":"en","teamMetrics":true}\n' > "$REPO/docs/ai-knowledge/lore.json"
( cd "$T" && LORE_METRICS_USER=alice bash "$HERE/lore-stats.sh" export-summary "$REPO" >/dev/null 2>&1 )
RJ="$REPO/docs/ai-knowledge/.metrics/alice.json"
if [ -f "$RJ" ] && jq -e '
	.user == "alice" and .window_days == 90
	and .files["t10.md"].loads == 2 and .files["t10.md"].used == 1
	and .files["t10.md"].ignored == 1 and .files["t10.md"].written == 1
	and (.files | has("foreign.md") | not)
	and ((tostring | contains("session")) | not)' "$RJ" >/dev/null 2>&1; then
	echo "PASS T10 export-summary: correct repo-scoped counts, no session ids"
else
	echo "FAIL T10 rollup: $(cat "$RJ" 2>/dev/null | head -c 300)"; fail=1
fi

# T11 team aggregation + never-loaded exclusion: a teammate's committed rollup must surface
# in the team section, and a file only THEY read must not be reported as never-loaded —
# while a control file nobody reads still must be (guards against the section silently dying)
cat > "$REPO/docs/ai-knowledge/never2.md" <<'EOF'
---
name: never2
description: control entry nobody reads
scope: repo
code-anchors: []
status: fact
provenance: test
env: all
promote: n/a
updated: 2026-01-01
---
body
EOF
jq -nc '{user:"bob", repo:"x", updated:"2026-08-30", window_days:90,
	gate:{fires:1, nothing_to_save:0},
	files:{"demo.md":{loads:3, used:2, ignored:0, contradicted:0, written:0}}}' \
	> "$REPO/docs/ai-knowledge/.metrics/bob.json"
out=$(cd "$REPO" && LORE_DATA_DIR="$FRESH" bash "$HERE/lore-stats.sh" codex 2>&1)
# demo.md aggregate = bob's rollup only (used 2 / ignored 0); alice's feedback went to t10.md
if printf '%s' "$out" | grep -q 'team rollups (committed .metrics/\*.json from 2 user' &&
	printf '%s' "$out" | grep -q 'used 2 / ignored 0' &&
	! printf '%s' "$out" | grep -q "$RB/demo.md (updated" &&
	printf '%s' "$out" | grep -q "$RB/never2.md (updated"; then
	echo "PASS T11 team rollups aggregate; teammate reads exclude a file from never-loaded (control still listed)"
else
	echo "FAIL T11 team section: $(printf '%s' "$out" | grep -A4 'team rollups' | head -6)"; fail=1
fi

# T12 exporting from a git WORKTREE must attribute to the main repo (raw basename would
# never match the normalized event keys → silently empty rollup)
MAIN="$T/mainrepo"
mkdir -p "$MAIN/docs/ai-knowledge"
git -C "$MAIN" init -q
git -C "$MAIN" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
git -C "$MAIN" worktree add -q "$T/wt-feature" -b feature 2>/dev/null
mkdir -p "$T/wt-feature/docs/ai-knowledge"
printf '{"teamMetrics":true}\n' > "$T/wt-feature/docs/ai-knowledge/lore.json"
printf '{"event":"kb_load","repo":"mainrepo","kb_repo":"mainrepo","file":"demo.md","reason":"include","session":"sw","ts":"%s"}\n' "$NOW" >> "$LORE_DATA_DIR/metrics.jsonl"
( cd "$T" && LORE_METRICS_USER=carol bash "$HERE/lore-stats.sh" export-summary "$T/wt-feature" >/dev/null 2>&1 )
WJ="$T/wt-feature/docs/ai-knowledge/.metrics/carol.json"
if [ -f "$WJ" ] && jq -e '.repo == "mainrepo" and .files["demo.md"].loads >= 1' "$WJ" >/dev/null 2>&1; then
	echo "PASS T12 worktree export attributes to the main repo (non-empty rollup)"
else
	echo "FAIL T12 worktree rollup: $(cat "$WJ" 2>/dev/null | head -c 200)"; fail=1
fi

# T13 hostile/broken rollups must not poison aggregation: negative and string counts clamp
# to 0, broken JSON is skipped, and the report survives
jq -nc '{user:"mallory", files:{"demo.md":{loads:-99, used:"9", ignored:2, contradicted:null}}}' \
	> "$REPO/docs/ai-knowledge/.metrics/mallory.json"
printf 'not json at all' > "$REPO/docs/ai-knowledge/.metrics/broken.json"
out=$(cd "$REPO" && LORE_DATA_DIR="$FRESH" bash "$HERE/lore-stats.sh" codex 2>&1)
rc=$?
# mallory contributes ignored 2 (clamped) but zero loads/used; demo.md totals become used 2 / ignored 2
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q 'used 2 / ignored 2' &&
	! printf '%s' "$out" | grep -q -- '-99'; then
	echo "PASS T13 hostile rollup clamped (negatives/strings → 0), broken JSON skipped, report intact"
else
	echo "FAIL T13 rc=$rc: $(printf '%s' "$out" | grep -A3 'team rollups' | head -4)"; fail=1
fi
rm -f "$REPO/docs/ai-knowledge/.metrics/mallory.json" "$REPO/docs/ai-knowledge/.metrics/broken.json"

# T14 the Codex installer's sed pipeline must route skill-run telemetry to the codex data
# dir: engine token → absolute path, record-write/export-summary gain codex arguments
SEDX="$T/skillsed"
mkdir -p "$SEDX"
SD='/tmp/x codex/lore/scripts'
esc=$(printf '%s' "$SD" | sed 's/[&\\|]/\\&/g')
sed -e "s|<engine-scripts>|$esc|g" \
	-e 's|/record-write.sh\([" ]*\) written|/record-write.sh\1 --format=codex written|g' \
	-e 's|/record-write.sh written|/record-write.sh --format=codex written|g' \
	-e 's|/lore-stats.sh\([" ]*\) export-summary|/lore-stats.sh\1 codex export-summary|g' \
	-e 's|/lore-stats.sh export-summary|/lore-stats.sh codex export-summary|g' \
	"$HERE/../skills/memorize/SKILL.md" > "$SEDX/memorize.md"
if grep -q 'record-write.sh" --format=codex written' "$SEDX/memorize.md" &&
	grep -q 'lore-stats.sh" codex export-summary' "$SEDX/memorize.md" &&
	grep -q "$SD" "$SEDX/memorize.md" &&
	! grep -q '<engine-scripts>' "$SEDX/memorize.md"; then
	echo "PASS T14 codex sed rewrite: absolute path baked, codex args added to telemetry commands"
else
	echo "FAIL T14 sed rewrite gaps: $(grep -n 'record-write.sh\|export-summary' "$SEDX/memorize.md" | head -3)"; fail=1
fi

# T15 anchor drift: an entry whose anchored file was committed AFTER its `updated` date must
# surface in the drift section with the commit count; an untouched anchor must not
mkdir -p "$REPO/src/api"
: > "$REPO/src/api/x.js"; : > "$REPO/src/api/quiet.js"
git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" -c user.email=t@example.com -c user.name=t commit -q -m "add files" >/dev/null 2>&1
cat > "$REPO/docs/ai-knowledge/drift.md" <<'EOF'
---
name: drift
description: anchored file keeps changing after this was written
scope: repo
code-anchors:
  - src/api/x.js
status: fact
provenance: test
env: all
promote: n/a
updated: 2026-01-01
---
body
EOF
cat > "$REPO/docs/ai-knowledge/quiet.md" <<'EOF'
---
name: quiet
description: anchored file untouched since this was written
scope: repo
code-anchors:
  - src/api/quiet.js
status: fact
provenance: test
env: all
promote: n/a
updated: 2099-01-01
---
body
EOF
printf 'changed\n' >> "$REPO/src/api/x.js"
git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" -c user.email=t@example.com -c user.name=t commit -q -m "touch x" >/dev/null 2>&1
out=$(cd "$REPO" && LORE_DATA_DIR="$FRESH" bash "$HERE/lore-stats.sh" codex 2>&1)
if printf '%s' "$out" | grep -q 'commit(s) since 2026-01-01 .*drift.md' && ! printf '%s' "$out" | grep -q 'quiet.md (updated\|since 2099.*quiet.md'; then
	echo "PASS T15 anchor drift lists the entry whose anchor changed after updated; untouched anchor absent"
else
	echo "FAIL T15 drift section: $(printf '%s' "$out" | grep -A3 'anchor drift' | head -4)"; fail=1
fi

# T16 polish prescription: an ignored-heavy entry with a directory anchor and a catch-all
# description gets a ↳ line naming both smells
cat > "$REPO/docs/ai-knowledge/broad.md" <<'EOF'
---
name: broad
description: Read before changing anything under the API layer
scope: repo
code-anchors:
  - src/api/
status: fact
provenance: test
env: all
promote: n/a
updated: 2026-01-01
---
body
EOF
for sid in q1 q2 q3; do
	printf '{"event":"kb_feedback","repo":"%s","session":"%s","file":"%s:broad.md","verdict":"ignored","ts":"%s"}\n' "$RB" "$sid" "$RB" "$NOW" >> "$LORE_DATA_DIR/metrics.jsonl"
done
out=$(cd "$REPO" && bash "$HERE/lore-stats.sh" codex 2>&1)
if printf '%s' "$out" | grep -q 'ignored 3 / used 0 .*broad.md' && printf '%s' "$out" | grep -q '↳ .*directory anchor' && printf '%s' "$out" | grep -q 'catch-all description'; then
	echo "PASS T16 polish candidate carries a prescription naming directory anchor + catch-all description"
else
	echo "FAIL T16 prescription: $(printf '%s' "$out" | grep -A1 'broad.md' | head -3)"; fail=1
fi

[ $fail -eq 0 ] && echo "== all passed ==" || echo "== failures =="
exit $fail
