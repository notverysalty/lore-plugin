#!/usr/bin/env bash
# lore generator index/lint regression tests (bash 3.2 compatible, self-contained temp dirs).
# Covers: lint hints for write-time smells (non-blocking, --strict enforces), flat vs grouped
# index switching by entry count, lore.json overrides (indexMode / indexGroupThreshold), config
# validation, and write mode exiting non-zero (but still writing) when an entry is invalid.
# Usage: bash test-gen-index.sh [path-to-gen-script]   Expect all PASS, exit 0.
set -u
GEN="${1:-$(cd "$(dirname "$0")" && pwd)/gen-knowledge-index.mjs}"
fail=0

mk_repo() {
  local d
  d=$(mktemp -d /tmp/lore-index-test.XXXXXX)
  mkdir -p "$d/docs/ai-knowledge" "$d/src/api" "$d/src/webhooks"
  : > "$d/src/api/orders.js"
  printf '%s' "$d"
}
# mk_entry <repo> <name> <description> <anchor-yaml-line-or-empty>
mk_entry() {
  {
    printf -- '---\nname: %s\ndescription: %s\nscope: repo\ncode-anchors:\n' "$2" "$3"
    if [ -n "$4" ]; then printf '  - %s\n' "$4"; else printf '  []\n'; fi
    printf 'status: fact\nprovenance: test\nenv: all\npromote: n/a\nupdated: 2026-01-01\n---\nbody\n'
  } > "$1/docs/ai-knowledge/$2.md"
}

# T1 lint hints: catch-all description + directory anchor → 2 hints, --check still passes
T=$(mk_repo)
mk_entry "$T" broad "Read before changing anything in the API layer" "src/api/"
node "$GEN" "$T" >/dev/null 2>&1
out=$(node "$GEN" "$T" --check 2>&1); rc=$?
n=$(printf '%s\n' "$out" | grep -c '^\[lint\]')
if [ $rc -eq 0 ] && [ "$n" -eq 2 ] && printf '%s' "$out" | grep -q 'catch-all' && printf '%s' "$out" | grep -q 'directory anchor'; then
  echo "PASS T1 lint: 2 hints (catch-all description, directory anchor), --check exit 0"
else
  echo "FAIL T1 rc=$rc hints=$n"; printf '%s\n' "$out" | head -5; fail=1
fi
# T2 --strict turns the same hints into failures
node "$GEN" "$T" --check --strict >/dev/null 2>&1; rc=$?
if [ $rc -eq 1 ]; then echo "PASS T2 --strict: lint hints fail the check"; else echo "FAIL T2 strict rc=$rc"; fail=1; fi
rm -rf "$T"

# T3 clean entry → no hints; flat index under the threshold
T=$(mk_repo)
mk_entry "$T" clean "orders endpoint returns 409 when cancelling a shipped order" "src/api/orders.js"
node "$GEN" "$T" >/dev/null 2>&1
out=$(node "$GEN" "$T" --check 2>&1)
if ! printf '%s' "$out" | grep -q '^\[lint\]' && ! grep -q '^## ' "$T/docs/ai-knowledge/INDEX.md" && grep -q 'shipped order' "$T/docs/ai-knowledge/INDEX.md"; then
  echo "PASS T3 clean entry: no hints; flat index with full description"
else
  echo "FAIL T3"; printf '%s\n' "$out" | head -3; fail=1
fi
rm -rf "$T"

# T4 above the default threshold (31 entries) → grouped index with trimmed descriptions
T=$(mk_repo)
LONG="orders endpoint returns 409 when cancelling a shipped order because the fulfillment provider only supports interception before handover, so callers must check shipment status first and surface the reason"
for i in $(seq 1 16); do mk_entry "$T" "api-$i" "$LONG variant $i" "src/api/orders.js"; done
for i in $(seq 1 15); do mk_entry "$T" "hook-$i" "webhook dispatcher retries variant $i" "src/webhooks/"; done
node "$GEN" "$T" >/dev/null 2>&1
IDX="$T/docs/ai-knowledge/INDEX.md"
if grep -q 'Grouped index (31 entries' "$IDX" && [ "$(grep -c '^## ' "$IDX")" -eq 2 ] && grep -q '^## src/api (16)' "$IDX" && grep -q '^## src/webhooks (15)' "$IDX" \
  && grep -q '…' "$IDX" && ! grep -q 'surface the reason' "$IDX" && node "$GEN" "$T" --check >/dev/null 2>&1; then
  echo "PASS T4 grouped index at 31 entries: 2 sections keyed by code area, descriptions trimmed, check clean"
else
  echo "FAIL T4"; grep -n '^## \|Grouped' "$IDX" | head -5; fail=1
fi
# T5 lore.json indexMode flat forces a flat index at the same size
printf '{"language":"en","indexMode":"flat"}' > "$T/docs/ai-knowledge/lore.json"
node "$GEN" "$T" >/dev/null 2>&1
if ! grep -q '^## ' "$IDX" && grep -q 'surface the reason' "$IDX"; then
  echo "PASS T5 indexMode=flat overrides auto grouping"
else
  echo "FAIL T5"; fail=1
fi
# T6 indexGroupThreshold=5 groups a small repo; indexMode grouped forces grouping regardless
printf '{"indexGroupThreshold":5}' > "$T/docs/ai-knowledge/lore.json"
node "$GEN" "$T" >/dev/null 2>&1
a=$(grep -c '^## ' "$IDX")
rm -rf "$T"
T=$(mk_repo)
mk_entry "$T" one "orders endpoint returns 409 when cancelling a shipped order" "src/api/orders.js"
printf '{"indexMode":"grouped"}' > "$T/docs/ai-knowledge/lore.json"
node "$GEN" "$T" >/dev/null 2>&1
b=$(grep -c '^## ' "$T/docs/ai-knowledge/INDEX.md")
if [ "$a" -eq 2 ] && [ "$b" -eq 1 ]; then
  echo "PASS T6 lore.json threshold and indexMode=grouped both honored"
else
  echo "FAIL T6 a=$a b=$b"; fail=1
fi
# T7 invalid config value is a problem (check exit 1)
printf '{"indexMode":"sideways","promotionTarget":42,"teamMetrics":"yes"}' > "$T/docs/ai-knowledge/lore.json"
out=$(node "$GEN" "$T" --check 2>&1); rc=$?
if [ $rc -eq 1 ] && printf '%s' "$out" | grep -q 'indexMode' && printf '%s' "$out" | grep -q 'promotionTarget' && printf '%s' "$out" | grep -q 'teamMetrics'; then
  echo "PASS T7 invalid lore.json values (indexMode, promotionTarget, teamMetrics) fail --check"
else
  echo "FAIL T7 rc=$rc"; printf '%s\n' "$out" | head -3; fail=1
fi
rm -rf "$T"

# T8 write mode with an invalid entry: artifacts still written, exit code non-zero
T=$(mk_repo)
mk_entry "$T" good "orders endpoint returns 409 when cancelling a shipped order" "src/api/orders.js"
mk_entry "$T" "Bad_Name" "x" ""
node "$GEN" "$T" >/dev/null 2>&1; rc=$?
if [ $rc -eq 1 ] && grep -q 'good' "$T/docs/ai-knowledge/INDEX.md" && ! grep -q 'Bad_Name' "$T/docs/ai-knowledge/INDEX.md"; then
  echo "PASS T8 write mode: invalid entry skipped, artifacts written, exit 1 signals the flow"
else
  echo "FAIL T8 rc=$rc"; fail=1
fi
rm -rf "$T"

[ $fail -eq 0 ] && echo "== all passed ==" || echo "== failures =="
exit $fail
