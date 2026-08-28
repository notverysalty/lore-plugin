# lore on Codex

lore's core is runtime-agnostic: the knowledge content (`docs/ai-knowledge/`), the gate scripts, and the generator are plain markdown + bash/node. This directory wires it into the OpenAI Codex CLI.

> Status: aligned with the Codex hooks & skills docs as of codex-cli 0.144.x (skills discovered from `~/.agents/skills`; Stop continuation via `{"decision":"block","reason"}`). The Codex surface moves fast — if install or the gate misbehaves on a newer CLI, please open an issue.

## Part mapping (Codex equivalents)

| lore part | Codex mechanism |
|---|---|
| Knowledge content `docs/ai-knowledge/` | Unchanged; Codex reads it directly |
| Retrieval pointer | `AGENTS.md` (Codex reads it natively; written per repo by init) |
| memorize / init / knowledge-consolidate / resolve-merge / set-language | Native Codex Skills, installed under `lore-*` prefixed names (same SKILL.md; the name and in-body references are rewritten on install; `agents/openai.yaml` controls implicit invocation) |
| Path-scoped rules (`.claude/rules/knowledge/`) | `PostToolUse` hook (`push-knowledge.sh`, matcher `apply_patch\|Edit\|Write`): an edit hitting a knowledge anchor path → inject that entry's read pointer. Reuses the same rules artifacts as the path→knowledge map — single source of truth |
| Automatic gate (wrap-up capture) | Codex `Stop` hook — emits `{"decision":"block","reason":...}` (same shape as Claude Code); the reason becomes an automatic continuation prompt |
| Session-start baseline | Codex `SessionStart` hook |

The gate/push scripts take a `codex` argument to emit Codex-format JSON; both runtimes share the same logic.

## Install

Prerequisites: this repo cloned, the Codex CLI installed, `python3` and `jq` available.

```bash
bash codex/install.sh
```

It will:
- Copy the skills to `~/.agents/skills/` (Codex's documented user-skill location) under `lore-*` prefixed directory and frontmatter names (with `agents/openai.yaml`; in-body `lore:*` references and script paths rewritten; earlier lore installs in the legacy `~/.codex/skills/` swept)
- Copy the gate + path-push + telemetry scripts to `~/.codex/lore/scripts/`
- Merge `~/.codex/hooks.json` (your existing hooks are preserved; SessionStart + Stop + PostToolUse all point at `--format=codex`)

Then, as prompted:
1. `/hooks` — trust the new hooks (Codex reviews unmanaged hooks once)
2. `/skills` — confirm the `lore-*` skills are discovered
3. Restart codex / open a new session

Uninstall: `bash codex/install.sh --uninstall`

## Known differences vs Claude Code

- **Skill naming**: Codex has no plugin namespace; skills install as `lore-` prefixed names — explicit invocation is `$lore-memorize`, mapping one-to-one to Claude Code's `lore:memorize`. Repo docs (AGENTS.md / INDEX.md) that mention `lore:memorize` mean `lore-memorize` on Codex (near-identical names + openai.yaml implicit invocation let the model connect them).
- **Path-push timing**: Claude Code's rules inject **before** a matched file is touched; Codex's PostToolUse push injects **after** the edit lands, effective next turn, and only covers edit actions (apply_patch/Edit/Write) — pure reading doesn't trigger it and falls back to the `AGENTS.md` static index. Each entry is pushed at most once per session.
- **Load metrics come from path-push hits only**: Codex has no InstructionsLoaded equivalent, so reads of the AGENTS index are not observable — `kb_load` events (and therefore feedback prompts, never-loaded, team rollups) reflect push-triggered loads, an undercount relative to Claude Code.
- **Skills directory is shared**: `~/.agents/skills` is a cross-runtime location, so the `lore-*` skill directories installed here may be visible to other agents too. The `lore-` prefix keeps them distinct from the Claude Code plugin's `lore:*` namespace; Claude Code users should simply not run this installer (see below). Verify with `/skills` after installing.
- **Trust**: Codex requires a one-time `/hooks` review for project/user-level hooks; Claude Code plugin hooks work immediately after install.

## ⚠️ Avoid double-installing (Claude Code users: do not run this script)

Claude Code users install the plugin (`/plugin install lore@<marketplace>`); **do not** also run this install.sh — one runtime, one channel. The skills land in the shared `~/.agents/skills` under `lore-` prefixed names: distinct from the plugin's `lore:*` namespace, but a Claude Code session that also discovers shared-directory skills would see near-duplicates. If you use both runtimes on one machine, keep the plugin for Claude Code and this installer for Codex — the prefixed names and the separate hook channels are designed to coexist, not to be doubled up within one runtime.
