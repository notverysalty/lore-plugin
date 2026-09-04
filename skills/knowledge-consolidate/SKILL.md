---
name: knowledge-consolidate
user-invocable: false
description: Periodic (monthly) knowledge-base governance. Use when the user asks to "consolidate the knowledge base", "clean up knowledge", "knowledge consolidate", "prune stale knowledge", "harvest pending cross-repo knowledge". Runs semantic dedupe, contradiction checks, polish of low-hit entries, pending harvest, retirement into archive, and index rebuild over the current repo's docs/ai-knowledge/. NOT for day-to-day capture (use memorize).
---

# knowledge-consolidate — periodic knowledge-base governance

Run one governance pass over the current repo's `docs/ai-knowledge/`. Output the changes as a normal PR (never commit/push on your own; report when done and let the user commit).

Deterministic checks (dead anchors, index drift) are covered by CI's `gen-knowledge-index.mjs --check`; this skill does only the parts that need semantic judgment.

**Language**: if `docs/ai-knowledge/lore.json` sets `"language"`, write any knowledge bodies/descriptions you touch in that language (frontmatter keys and enum values stay English).

## Governance steps

1. **Baseline** (`<engine-scripts>` = the absolute scripts path injected into context when this skill was invoked — the line starting `lore engine scripts:`; on Codex the installer bakes the real path in): run `node "<engine-scripts>/gen-knowledge-index.mjs" <repo-root> --check` and record the dead anchors and drift it reports. `.gitattributes` union entries and the directory gate files are detected item-by-item by the generator (missing pieces show up as drift) and are auto-backfilled by step 8's rebuild — this is also the backfill channel for repos onboarded before those features existed.
   > Write authorization: `docs/ai-knowledge/` is guarded by a PreToolUse gate; invoking this skill auto-issued the grant (bounded uses, cleared at Stop, short-TTL backstop). If a large pass exhausts it, invoke this skill again to continue — do not work around the gate.
2. **Dead and drifting anchors**: for each broken code-anchor, find the code's new location: fix the frontmatter when possible; if the knowledge no longer has corresponding code → mark it for retirement. Then take `/lore:stats`'s **anchor drift** list (anchored code committed after the entry's `updated` date, ranked by commit count) — the file still exists but has moved on; re-read that code and refresh, or downgrade to `hypothesis` if it no longer holds.
3. **Semantic dedupe & contradictions**: start from `/lore:stats`'s "⚠️ contradiction follow-up" list (files flagged contradicted at session wrap-ups) — these are the likely silently-stale entries; verify each against the code, rewrite or downgrade. Then group all knowledge files by `related`/topic and compare pairwise: duplicates → merge into one (keep the richer file, delete the other); contradictions → verify against code, rewrite with the code as truth; unverifiable → downgrade to `status: hypothesis` and note the contradiction in the body.
4. **Polish candidates (retrieved but not helping)**: from `/lore:stats`'s "polish candidates" list (ignored ≥ 2 and > used) — each carries a `↳` prescription line derived from the write-time smells; start there, then confirm by diagnosing: description too broad ("read before changing X" phrasing)? directory-level anchors on hot paths? one file bundling several topics? body duplicating what CLAUDE.md already loads? Fix per the memorize quality rules — narrow descriptions to symptoms, anchor to the specific contract-bearing files, split multi-topic digests (cross-link via `related`), strip content CLAUDE.md already covers.
5. **Never-loaded entries**: stats' "never loaded" list (zero loads ever, older than 14 days) = retire-or-activate candidates. Entries in repos with no development activity → propose archiving; entries whose description lacks symptom keywords → rewrite the description so retrieval can find them.
6. **Hypothesis review**: for each `status: hypothesis` file — promote to `fact` when code/behavior verifies it; older than 90 days and still unverifiable → ask the user whether to delete.
7. **Pending harvest**: list every entry with `scope: cross-repo` and `promote: pending`. Where they go: if `docs/ai-knowledge/lore.json` sets `promotionTarget` (the team's cross-repo memory layer — e.g. a Hindsight/Mem0-style memory bank exposed over MCP, a shared knowledge repo, or a wiki space), promote each entry there as one compact durable fact (conclusion + `provenance: lore:<repo>/<file>`), set `promote: done`, and keep the in-repo file as the code-anchored detail. Without a target, summarize the list and ask the user where cross-repo knowledge should live — a pending backlog that never drains means the team has no cross-repo layer yet, which is worth deciding explicitly.
8. **Retire into archive**: move confirmed-obsolete files to `docs/ai-knowledge/archive/` (mv, never delete) — gone from the index, still grep-able. Confirm each retirement with the user; never batch-retire silently.
9. **Rebuild**: run the generator (without --check) to refresh INDEX.md and rules, then, only if `lore.json` sets `"teamMetrics": true` (team metrics are opt-in; the script is a no-op otherwise), refresh your per-user metrics rollup (`bash "<engine-scripts>/lore-stats.sh" export-summary <repo-root>` — rewrites only your own `docs/ai-knowledge/.metrics/<user>.json`); report the pass summary (fixed X, merged Y, polished P, retired Z, pending-harvest N).

## Hard rules

- Every change must be explainable: one-line rationale per action in the report.
- When unsure, keep the entry and annotate it; never silently delete knowledge.
- Touch nothing outside `docs/ai-knowledge/`, the generated artifacts the rebuild owns (`.claude/rules/knowledge/`, the `.gitattributes` union entries), and missing CLAUDE.md/AGENTS.md pointer lines.
