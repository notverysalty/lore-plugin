# lore CI check (optional per-repo add-on)

`knowledge-check.yml` is a CI template for onboarded repos: on PRs touching `docs/ai-knowledge/**`, `.claude/rules/knowledge/**`, or `.gitattributes`, it runs `gen-knowledge-index.mjs --check` to catch invalid frontmatter, dead code-anchors, and drift between the source knowledge files and the generated INDEX/rules/gate files.

## Getting the generator into CI (two options)

| Option | How | Trade-off |
|---|---|---|
| **A. Vendor** | Commit a copy of the generator at `docs/ai-knowledge/.lore/gen-knowledge-index.mjs` | Zero network dependency; cost: the vendored copy doesn't auto-update when the generator evolves (it is stable — only frontmatter-field changes require an update) |
| **B. Fetch (default)** | CI curls the generator from the public lore-plugin repo at a pinned ref | Never forks; no token needed for a public repo. Pin `LORE_PLUGIN_REF` to a tag for reproducibility |

The template auto-selects with `hashFiles`: vendored copy present → A, otherwise → B.

## Why bother (defense layering)

The write policy has an honest boundary: the PreToolUse write gate intercepts direct edits **inside lore-equipped Claude Code sessions only**. Everything else — writes via Bash, agents without the plugin, human hand-edits, `--no-verify` commits — skips the hook. CI `--check` is the layer nothing skips, because nothing skips the PR:

- **PreToolUse hook**: catches direct edits in-session, before they land (tool layer).
- **This CI check**: catches every write path that bypassed the tool layer (git layer backstop).

Recommended for repos with multiple people or multiple agents actively writing knowledge. Small, rarely-changed knowledge bases can defer it and rely on the skill flows plus an occasional manual `--check`.
