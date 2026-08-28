#!/usr/bin/env bash
# lore gen concurrency-lock regression tests (bash 3.2 compatible, self-contained temp dir).
# Covers the review scenarios: a legitimate holder exceeding the threshold gets taken over
# and yields (no interleaved writes); two reclaimers never delete each other's fresh lock.
# Usage: bash test-gen-lock.sh [path-to-gen-script]   Expect all PASS, exit 0.
set -u
GEN="${1:-$(cd "$(dirname "$0")" && pwd)/gen-knowledge-index.mjs}"
T=$(mktemp -d /tmp/lore-lock-test.XXXXXX)
KB="$T/docs/ai-knowledge"
mkdir -p "$KB"
cat > "$KB/demo.md" <<'EOF'
---
name: demo
description: test entry
scope: repo
code-anchors: []
status: fact
provenance: test
env: all
promote: n/a
updated: 2026-07-14
---
body
EOF
fail=0

# T1 basic mutual exclusion: a fresh lock is held → wait ~1.5s, give up with exit 1,
# and never touch someone else's lock
mkdir -p "$KB/.gen-lock"; printf 'someone-else' > "$KB/.gen-lock/owner"
node "$GEN" "$T" >/dev/null 2>&1
rc=$?
if [ $rc -eq 1 ] && [ -d "$KB/.gen-lock" ] && [ "$(cat "$KB/.gen-lock/owner")" = "someone-else" ]; then
  echo "PASS T1 mutex: gave up after waiting, foreign lock untouched"
else
  echo "FAIL T1 rc=$rc"; fail=1
fi
rm -rf "$KB/.gen-lock"

# T2 (review scenario: legitimate slow run beyond the threshold gets taken over + the
# resurrected holder yields): A takes the lock and simulates a 4s slow scan; the test ages
# the owner mtime to trigger stale; B takes over and completes the write; A wakes up, sees
# a different owner → yields with exit 1, and its exit handler must not delete B's lock.
node_env_hold() { LORE_GEN_TEST_HOLD_MS=4000 node "$GEN" "$T" >/dev/null 2>&1; }
node_env_hold & A=$!
i=0
while [ $i -lt 50 ]; do
  [ -f "$KB/.gen-lock/owner" ] && break
  sleep 0.1; i=$((i+1))
done
touch -t 202601010000 "$KB/.gen-lock/owner"
node "$GEN" "$T" >/dev/null 2>&1
b=$?
wait $A
a=$?
if [ $b -eq 0 ] && [ $a -eq 1 ] && [ ! -d "$KB/.gen-lock" ]; then
  echo "PASS T2 stale takeover: B took over and wrote (0), resurrected A yielded (1), no leftover lock"
else
  echo "FAIL T2 B=$b A=$a lock=$([ -d "$KB/.gen-lock" ] && echo leftover || echo none)"; fail=1
fi

# T3 (review scenario: two reclaimers race for a stale lock): rename quarantine guarantees
# they never delete each other's fresh lock; outcome = serialized (at least one succeeds),
# no leftovers, zero drift.
mkdir -p "$KB/.gen-lock"; printf 'dead-holder' > "$KB/.gen-lock/owner"
touch -t 202601010000 "$KB/.gen-lock/owner"
node "$GEN" "$T" >/dev/null 2>&1 & B=$!
node "$GEN" "$T" >/dev/null 2>&1 & C=$!
wait $B; b=$?
wait $C; c=$?
node "$GEN" "$T" --check >/dev/null 2>&1
k=$?
if { [ $b -eq 0 ] || [ $c -eq 0 ]; } && [ ! -d "$KB/.gen-lock" ] && [ $k -eq 0 ]; then
  echo "PASS T3 dual reclaimers: serialized (B=$b C=$c), no leftovers, check clean"
else
  echo "FAIL T3 B=$b C=$c check=$k"; fail=1
fi

# T4 normal concurrent races, 3 rounds × 2 processes: all succeed under wait-and-retry
ok=1
r=0
while [ $r -lt 3 ]; do
  node "$GEN" "$T" >/dev/null 2>&1 & P1=$!
  node "$GEN" "$T" >/dev/null 2>&1 & P2=$!
  wait $P1 || ok=0
  wait $P2 || ok=0
  r=$((r+1))
done
if [ $ok -eq 1 ] && [ ! -d "$KB/.gen-lock" ]; then
  echo "PASS T4 3×2 concurrent races all succeeded, no leftovers"
else
  echo "FAIL T4"; fail=1
fi

rm -rf "$T"
[ $fail -eq 0 ] && echo "== all passed ==" || echo "== failures =="
exit $fail
