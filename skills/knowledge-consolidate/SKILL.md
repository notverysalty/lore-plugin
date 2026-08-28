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
2. **Dead anchors**: for each broken code-anchor, find the code's new location: fix the frontmatter when possible; if the knowledge no longer has corresponding code → mark it for retirement.
3. **Semantic dedupe & contradictions**: start from `/lore:stats`'s "⚠️ contradiction follow-up" list (files flagged contradicted at session wrap-ups) — these are the likely silently-stale entries; verify each against the code, rewrite or downgrade. Then group all knowledge files by `related`/topic and compare pairwise: duplicates → merge into one (keep the richer file, delete the other); contradictions → verify against code, rewrite with the code as truth; unverifiable → downgrade to `status: hypothesis` and note the contradiction in the body.
4. **Polish candidates (retrieved but not helping)**: from `/lore:stats`'s "polish candidates" list (ignored ≥ 2 and > used), diagnose each: description too broad ("read before changing X" phrasing)? directory-level anchors on hot paths? one file bundling several topics? body duplicating what CLAUDE.md already loads? Fix per the memorize quality rules — narrow descriptions to symptoms, anchor to the specific contract-bearing files, split multi-topic digests (cross-link via `related`), strip content CLAUDE.md already covers.
5. **Never-loaded entries**: stats' "never loaded" list (zero loads ever, older than 14 days) = retire-or-activate candidates. Entries in repos with no development activity → propose archiving; entries whose description lacks symptom keywords → rewrite the description so retrieval can find them.
6. **Hypothesis review**: for each `status: hypothesis` file — promote to `fact` when code/behavior verifies it; older than 90 days and still unverifiable → ask the user whether to delete.
7. **Pending harvest**: list every entry with `scope: cross-repo` and `promote: pending`; summarize for the user which should move up to their owning repos (or a shared knowledge location), and after the user confirms, set `promote: done` and draft the promoted content.
8. **Retire into archive**: move confirmed-obsolete files to `docs/ai-knowledge/archive/` (mv, never delete) — gone from the index, still grep-able. Confirm each retirement with the user; never batch-retire silently.
9. **Rebuild**: run the generator (without --check) to refresh INDEX.md and rules, then refresh your per-user metrics rollup (`bash "<engine-scripts>/lore-stats.sh" export-summary <repo-root>` — rewrites only your own `docs/ai-knowledge/.metrics/<user>.json`); report the pass summary (fixed X, merged Y, polished P, retired Z, pending-harvest N).

## Hard rules

- Every change must be explainable: one-line rationale per action in the report.
- When unsure, keep the entry and annotate it; never silently delete knowledge.
- Touch nothing outside `docs/ai-knowledge/`, the generated artifacts the rebuild owns (`.claude/rules/knowledge/`, the `.gitattributes` union entries), and missing CLAUDE.md/AGENTS.md pointer lines.
