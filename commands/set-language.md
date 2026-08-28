---
description: Set the language knowledge is written in for this repo (optionally translate existing entries)
---

Use the `set-language` skill to change the knowledge language of the current repo: write the `language` field in `docs/ai-knowledge/lore.json` (BCP 47 tag, e.g. `en`, `zh-CN`, `ja`). New knowledge captured by memorize/consolidate will be written in that language. Optionally translate existing knowledge bodies and descriptions in the same pass (frontmatter keys/enums and generated artifacts always stay English), then rebuild the index.
