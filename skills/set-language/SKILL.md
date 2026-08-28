---
name: set-language
user-invocable: false
description: Set the language knowledge is written in for the current repo (docs/ai-knowledge/lore.json "language" field), optionally translating existing entries. Use when the user says "write knowledge in <language>", "set the knowledge base language", "switch lore to Chinese/Japanese/…", or runs /lore:set-language. NOT for translating arbitrary repo docs — this only governs the lore knowledge base.
---

# set-language — choose the knowledge language for this repo

The knowledge language is a per-repo setting stored in `docs/ai-knowledge/lore.json`. It governs the **body and `description`** of knowledge files that memorize / knowledge-consolidate write. It does **not** localize: frontmatter keys and enum values (`status: fact`, `scope: repo`, …), generated artifacts (INDEX header, gate files, rules), or the stats report — those stay English so the engine and any model can consume them.

> Write authorization: `docs/ai-knowledge/` is guarded by a PreToolUse gate; invoking this skill auto-issued the grant (bounded uses, cleared at Stop, short-TTL backstop). If a large translation pass exhausts it, invoke this skill again to continue.

## Steps

1. **Precondition**: the repo must be onboarded (`docs/ai-knowledge/` exists); otherwise suggest lore:init and stop.
2. **Resolve the target language**: from the user's request, as a BCP 47 tag (`en`, `zh-CN`, `ja`, `de`, …). Confirm if ambiguous.
3. **Write the config**: create or update `docs/ai-knowledge/lore.json`, e.g. `{"language": "zh-CN"}` (preserve any other fields present). From now on, new knowledge in this repo is written in that language.
4. **Offer to translate existing entries** (optional; ask, don't assume): if the user wants existing knowledge migrated, for each knowledge file (skip `INDEX.md`, `AGENTS.md`, `CLAUDE.md`, `lore.json`, `archive/`):
   - Translate the body and the frontmatter `description` faithfully — keep code identifiers, error strings, paths, and quoted log lines verbatim (they are retrieval keys); keep all other frontmatter values unchanged.
   - Refresh `updated` to today and append a note to `provenance` (e.g. `; translated to zh-CN 2026-08-28`).
5. **Rebuild** (`<engine-scripts>` = the absolute scripts path injected into context when this skill was invoked — the line starting `lore engine scripts:`; on Codex the installer bakes the real path in): run `node "<engine-scripts>/gen-knowledge-index.mjs" <repo-root>` so the INDEX picks up translated descriptions; then `--check` to confirm zero drift.
6. **Report**: state the new language, how many files were translated (if any), and remind the user the changes ride a normal PR (do not commit on your own).

## Hard rules

- Never translate error messages, identifiers, commands, or code snippets inside knowledge bodies — those are exact-match retrieval keys.
- Frontmatter keys/enums and generated artifacts stay English regardless of the configured language.
- No auto-commit.
