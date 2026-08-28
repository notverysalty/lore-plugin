---
description: Semantically resolve git merge conflicts in knowledge files (union — never drop knowledge; regenerate artifacts)
---

Use the `resolve-merge` skill to resolve git merge conflicts under `docs/ai-knowledge/`: identify conflicted files → merge knowledge files semantically by frontmatter + body union (never drop an entry) → never hand-resolve generated artifacts (INDEX / rules) — rerun the generator to converge → PII self-check → validate with `--check`. Does not auto-commit; the user reviews and continues the merge / rebase.
