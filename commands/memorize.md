---
description: Persist business knowledge learned this session into docs/ai-knowledge/ (the lore knowledge base)
---

Use the `memorize` skill to run this session's knowledge-capture flow: decide whether anything qualifies as a "fact you cannot derive from the code" (cross-repo conventions, implicit rules, pitfalls with causes, anti-knowledge) → read INDEX to dedupe (update beats create) → route by scope (in-repo / cross-repo decision tree) → PII self-check → write to `docs/ai-knowledge/` per the frontmatter spec → rebuild the index and rules. When in doubt, save nothing — reply with a one-line reason and stop.
