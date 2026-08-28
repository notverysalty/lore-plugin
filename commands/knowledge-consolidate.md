---
description: Monthly governance of the lore knowledge base (dedupe / resolve conflicts / harvest pending / polish / archive / rebuild index)
---

Use the `knowledge-consolidate` skill to run a governance pass over the current repo's `docs/ai-knowledge/`: semantic dedupe, contradiction checks, polish of high-load/low-hit entries, harvest of `promote: pending` cross-repo knowledge, retirement of stale entries into archive, and index/rules rebuild. Output as a normal PR, one-line rationale per action; when unsure, keep the entry rather than delete it.
