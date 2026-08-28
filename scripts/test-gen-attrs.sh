#!/usr/bin/env bash
# lore gen .gitattributes regression tests (bash 3.2 compatible, self-contained temp dirs).
# Covers the review scenarios: per-entry union backfill on legacy onboarded repos,
# fresh-file creation, no-op when complete, foreign content preservation, and
# --check catching deleted union lines (the executable counterpart of the CI
# `.gitattributes` trigger-path scenario).
# Usage: bash test-gen-attrs.sh [path-to-gen-script]   Expect all PASS, exit 0.
set -u
GEN="${1:-$(cd "$(dirname "$0")" && pwd)/gen-knowledge-index.mjs}"
fail=0

COMMENT='# lore generated artifacts (union-merged where set; rerun the generator to converge; CI --check backstops drift)'
L_INDEX='docs/ai-knowledge/INDEX.md merge=union linguist-generated=true'
L_AGENTS='docs/ai-knowledge/AGENTS.md merge=union linguist-generated=true'
L_CLAUDE='docs/ai-knowledge/CLAUDE.md merge=union linguist-generated=true'
L_RULES='.claude/rules/knowledge/*.md merge=union linguist-generated=true'
L_METRICS='docs/ai-knowledge/.metrics/*.json linguist-generated=true'

# Build a minimal onboarded repo fixture with one valid knowledge file.
mk_repo() {
  local d
  d=$(mktemp -d /tmp/lore-attrs-test.XXXXXX)
  mkdir -p "$d/docs/ai-knowledge"
  cat > "$d/docs/ai-knowledge/demo.md" <<'EOF'
---
name: demo
description: test entry
scope: repo
code-anchors: []
status: fact
provenance: test
env: all
promote: n/a
updated: 2026-07-31
---
body
EOF
  printf '%s' "$d"
}

# T1 legacy onboarded repo: foreign content around an old 2-line lore block.
# --check must flag the 2 missing lines; write must insert them right after the
# existing lore block, keep foreign lines intact, and be idempotent.
T=$(mk_repo)
cat > "$T/.gitattributes" <<EOF
*.png binary

$COMMENT
$L_INDEX
$L_RULES

yarn.lock -diff
EOF
out=$(node "$GEN" "$T" --check 2>&1)
rc=$?
node "$GEN" "$T" >/dev/null 2>&1
cat > "$T/.expected" <<EOF
*.png binary

$COMMENT
$L_INDEX
$L_RULES
$L_AGENTS
$L_CLAUDE
$L_METRICS

yarn.lock -diff
EOF
cp "$T/.gitattributes" "$T/.after1"
node "$GEN" "$T" >/dev/null 2>&1
if [ $rc -eq 1 ] && printf '%s' "$out" | grep -q 'missing 3 generated-artifact union' \
  && cmp -s "$T/.gitattributes" "$T/.expected" && cmp -s "$T/.gitattributes" "$T/.after1" \
  && node "$GEN" "$T" --check >/dev/null 2>&1; then
  echo "PASS T1 legacy backfill: check flags 3 missing lines, write inserts after the existing block, foreign content kept, idempotent"
else
  echo "FAIL T1 rc=$rc"; diff "$T/.expected" "$T/.gitattributes" 2>&1 | head -10; fail=1
fi
rm -rf "$T"

# T2 fresh repo without .gitattributes: created with comment header + all 4 entries,
# and the gate files come out alongside.
T=$(mk_repo)
node "$GEN" "$T" >/dev/null 2>&1
cat > "$T/.expected" <<EOF
$COMMENT
$L_INDEX
$L_AGENTS
$L_CLAUDE
$L_RULES
$L_METRICS
EOF
if cmp -s "$T/.gitattributes" "$T/.expected" \
  && [ -f "$T/docs/ai-knowledge/AGENTS.md" ] && [ -f "$T/docs/ai-knowledge/CLAUDE.md" ] \
  && node "$GEN" "$T" --check >/dev/null 2>&1; then
  echo "PASS T2 fresh repo: full block created (comment header + 5 entries), gate files emitted alongside"
else
  echo "FAIL T2"; diff "$T/.expected" "$T/.gitattributes" 2>&1 | head -10; fail=1
fi
rm -rf "$T"

# T3 already complete: write mode must leave the file byte-identical.
T=$(mk_repo)
cat > "$T/.gitattributes" <<EOF
$COMMENT
$L_INDEX
$L_AGENTS
$L_CLAUDE
$L_RULES
$L_METRICS
EOF
cp "$T/.gitattributes" "$T/.before"
node "$GEN" "$T" >/dev/null 2>&1
if cmp -s "$T/.gitattributes" "$T/.before"; then
  echo "PASS T3 already complete: file untouched"
else
  echo "FAIL T3 file was modified"; fail=1
fi
rm -rf "$T"

# T4 foreign content but zero lore entries: full commented block appended at EOF,
# foreign line preserved.
T=$(mk_repo)
printf '*.mp4 binary\n' > "$T/.gitattributes"
node "$GEN" "$T" >/dev/null 2>&1
cat > "$T/.expected" <<EOF
*.mp4 binary

$COMMENT
$L_INDEX
$L_AGENTS
$L_CLAUDE
$L_RULES
$L_METRICS
EOF
if cmp -s "$T/.gitattributes" "$T/.expected" && node "$GEN" "$T" --check >/dev/null 2>&1; then
  echo "PASS T4 foreign content, zero lore lines: full block appended at EOF, original preserved"
else
  echo "FAIL T4"; diff "$T/.expected" "$T/.gitattributes" 2>&1 | head -10; fail=1
fi
rm -rf "$T"

# T5 union line deleted on a converged repo (the CI trigger-path scenario):
# --check must fail naming .gitattributes; regenerating must restore the line.
T=$(mk_repo)
node "$GEN" "$T" >/dev/null 2>&1
cp "$T/.gitattributes" "$T/.converged"
grep -v 'docs/ai-knowledge/AGENTS.md merge=union' "$T/.gitattributes" > "$T/.tampered" \
  && mv "$T/.tampered" "$T/.gitattributes"
out=$(node "$GEN" "$T" --check 2>&1)
rc=$?
node "$GEN" "$T" >/dev/null 2>&1
if [ $rc -eq 1 ] && printf '%s' "$out" | grep -q 'missing 1 generated-artifact union' \
  && grep -qxF "$L_AGENTS" "$T/.gitattributes" \
  && node "$GEN" "$T" --check >/dev/null 2>&1; then
  echo "PASS T5 deleted union line: check catches it (exit 1), regeneration restores it"
else
  echo "FAIL T5 rc=$rc out=$out"; fail=1
fi
rm -rf "$T"

# T6 symlink containment: the generator runs automatically inside skill flows, so a repo
# must not be able to point its writes outside itself.
# T6a a target artifact that is a symlink is refused (write mode exits non-zero, link intact)
T=$(mk_repo)
OUT=$(mktemp -d /tmp/lore-attrs-out.XXXXXX)
printf 'precious\n' > "$OUT/victim"
ln -s "$OUT/victim" "$T/docs/ai-knowledge/INDEX.md"
node "$GEN" "$T" >/dev/null 2>&1
rc=$?
if [ $rc -ne 0 ] && [ "$(cat "$OUT/victim")" = "precious" ] && [ -L "$T/docs/ai-knowledge/INDEX.md" ]; then
  echo "PASS T6a symlinked artifact target refused, external file untouched"
else
  echo "FAIL T6a rc=$rc victim=$(cat "$OUT/victim")"; fail=1
fi
rm -rf "$T" "$OUT"

# T6b a rules dir that is a symlink out of the repo is refused before any write/delete
T=$(mk_repo)
OUT=$(mktemp -d /tmp/lore-attrs-out.XXXXXX)
mkdir -p "$OUT/outside" "$T/.claude/rules"
printf 'keep me\n' > "$OUT/outside/stale.md"
ln -s "$OUT/outside" "$T/.claude/rules/knowledge"
node "$GEN" "$T" >/dev/null 2>&1
rc=$?
if [ $rc -ne 0 ] && [ -f "$OUT/outside/stale.md" ]; then
  echo "PASS T6b symlinked rules dir refused, external files untouched"
else
  echo "FAIL T6b rc=$rc"; fail=1
fi
rm -rf "$T" "$OUT"

[ $fail -eq 0 ] && echo "== all passed ==" || echo "== failures =="
exit $fail
