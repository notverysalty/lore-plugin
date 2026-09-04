# lore

English | [简体中文](README.zh-CN.md)

A knowledge engine for AI coding agents: after every substantial coding session, the "facts you cannot derive from the code" get captured into the repo — and get read back on demand the next time they matter.

- **Content lives in each repo** at `docs/ai-knowledge/` — plain, runtime-agnostic markdown, reviewed in normal code PRs
- **The engine is this plugin** (skills + hooks + a generator) — installed per person, effective in every onboarded repo
- **The loop closes with metrics** — tracked loads are judged used / ignored / contradicted at session wrap-up, so stale and useless knowledge is found by data, not by vibes

## Why not just CLAUDE.md / agent memory / RAG?

| | lore |
|---|---|
| CLAUDE.md | CLAUDE.md is loaded whole, every session — it must stay small and generic. lore entries load **on demand** (an index line + path-scoped push when you touch the anchored code), so the knowledge base can grow without taxing every session. lore's capture rubric explicitly rejects anything CLAUDE.md already covers. |
| Per-user agent memory | Personal memory is invisible to your teammates and dies with your account. lore knowledge is **a file in the repo, PR-reviewed by humans**, shared by every agent and every person. |
| RAG over docs | RAG retrieves text; nothing tells you whether retrieval *helped*. lore instruments the full funnel — captured → loaded → used/ignored/contradicted — and ships the governance flow (`knowledge-consolidate`) that consumes those metrics. |

What counts as knowledge here: **facts you cannot derive from the code** — implicit business rules, cross-repo conventions, pitfalls with causes, and anti-knowledge ("the model assumes X, the truth is Y"). Code structure, schemas, and task status are explicitly rejected by the capture rubric.

## Quickstart

```
/plugin marketplace add notverysalty/lore-plugin
/plugin install lore@lore-plugin
```

Then, in a repo you care about:

1. `/lore:init` — creates the `docs/ai-knowledge/` skeleton, CLAUDE.md/AGENTS.md pointers, and walks you through seeding the first few real entries (don't skip seeding — an empty knowledge base gives the automation nothing to work with). Already have ADRs, postmortems or runbooks? `/lore:harvest` mines them in bulk, with confirmation — the fastest way past the cold start.
2. Work normally. When a session did substantial work, the Stop gate asks the agent to evaluate whether anything is worth capturing (`nothing to save` is a legitimate, encouraged answer).
3. When you edit code covered by a knowledge anchor, the matching entry is pushed into context automatically.
4. `/lore:stats` — the health report: capture funnel, hit rates, polish candidates, contradiction follow-ups.
5. Monthly-ish: `/lore:knowledge-consolidate` — data-driven governance (dedupe, fix stale entries, polish low-hit ones, archive dead ones).

## What's in the box

| Part | Role |
|---|---|
| skill `lore:init` | One-shot repo onboarding: skeleton + pointers + settings + seeding |
| skill `lore:memorize` | Capture: rubric → dedupe → scope routing → write → rebuild index |
| skill `lore:knowledge-consolidate` | Governance: dedupe/contradictions, polish low-hit entries, harvest pending, archive |
| skill `lore:resolve-merge` | Git merge conflicts in knowledge files: semantic union merge — never lose an entry |
| skill `lore:set-language` | Per-repo knowledge language (`docs/ai-knowledge/lore.json`), optional translation of existing entries |
| skill `lore:harvest` | Bulk import: mine existing docs (ADRs, postmortems, runbooks, pasted text) for facts the code can't tell you; candidates confirmed before writing |
| command `/lore:doctor` | Self-check: dependencies, hook registration, per-channel liveness, dry-run gates, repo `--check` and index scale — because every hook fails open, breakage is otherwise silent |
| hook `SessionStart` | Records the session's starting HEAD (baseline for "cumulative changes") |
| hook `Stop` | Layer 1 of the two-layer gate: only sessions with substantial work trigger the capture evaluation; also collects used/ignored/contradicted verdicts for knowledge loaded this session |
| hook `PreToolUse` + `PostToolUse` | The write gate: knowledge files are writable only while a lore skill's instructions are in context (turn-scoped, hook-issued grant); generated artifacts are never hand-editable |
| hook `InstructionsLoaded` | Async telemetry: records knowledge files being loaded (read-rate metric) |
| `scripts/lore-stats.sh` (`/lore:stats`, `--since=YYYY-MM-DD`) | Capture funnel / read effectiveness & 14-day trend / polish candidates **with a fix prescription each** / contradiction follow-up / team rollups / **anchor drift** (anchored code changed after the entry was written) / inventory (pending backlog, never-loaded, time-to-first-use); `export-summary` writes your per-user team rollup into the repo, only where the repo opts in (`teamMetrics`) |
| `scripts/gen-knowledge-index.mjs` | Generates INDEX.md (flat, or grouped by code area once a repo grows) + `.claude/rules/knowledge/*.md` + the write-gate files from frontmatter; validates frontmatter and lints write-time smells (catch-all descriptions, directory anchors, oversized files — `--strict` makes them errors); concurrency-locked writes; `--check` mode for CI |

## Behavior boundaries (opt-in by design)

Every hook first checks whether the current repo has `docs/ai-knowledge/`: **absent → silent exit**. The plugin is enabled globally but only ever *does* anything in onboarded repos; every other project sees zero behavior.

The Stop gate stays silent unless real work happened (any of: loop guard, inside a subagent, not opted in, < 10 cumulative changed lines and < 8 real user turns since session start, already evaluated twice this session, same change fingerprint as the last evaluation, any script error).

## Scaling: flat vs grouped index

INDEX.md is loaded whole every session, so a flat list would eventually recreate the "CLAUDE.md is too big" problem lore exists to avoid. Above a threshold (30 entries by default) the generator switches the index to **grouped mode**: one section per anchored code area (the first two path segments of an entry's first anchor), with trimmed descriptions — the head of a description carries its symptom keywords, and the full trigger list lives in the file's frontmatter. Path-scoped rules are unaffected. Tune via `docs/ai-knowledge/lore.json`: `"indexMode": "flat" | "grouped" | "auto"` and `"indexGroupThreshold": 30`. `/lore:doctor` warns as a repo approaches the threshold.

## Knowledge language

Engine text, generated artifacts, and frontmatter are always English. The language knowledge is *written in* is per-repo: `docs/ai-knowledge/lore.json` → `{"language": "zh-CN"}` (set at init, or later via `/lore:set-language`, which can also translate existing entries). Error strings, identifiers, and code snippets are never translated — they are exact-match retrieval keys.

## Write policy (reads open, writes gated)

`docs/ai-knowledge/` is open to read for every runtime. Writes must go through the lore flows (memorize / consolidate / resolve-merge / init / set-language). The generator emits `AGENTS.md` / `CLAUDE.md` gate files inside every knowledge dir (themselves generated, drift-checked): agents without lore are told to put candidate knowledge in the PR description instead, keeping only the trust-protocol minimal correction. In lore-equipped Claude Code sessions a hook enforces this: knowledge files require a turn-scoped, hook-issued grant (no manual grant command exists); generated artifacts are denied unconditionally. Honest boundary: writes via Bash bypass any hook — repo-side CI (`ci/knowledge-check.yml`) is the layer nothing bypasses, because nothing bypasses the PR.

## CI (recommended per onboarded repo)

```yaml
- run: node <plugin-or-vendored-path>/gen-knowledge-index.mjs . --check
```

Validates frontmatter (kebab-case unique names, enums, dates, `lore.json`), live anchors, zero artifact drift, and complete `.gitattributes` union entries; prints **lint hints** for the write-time smells that make knowledge get ignored (catch-all descriptions, directory anchors, oversized files) — add `--strict` to turn hints into failures. Trigger paths must include `docs/ai-knowledge/**`, `.claude/rules/knowledge/**`, **and** `.gitattributes` (template: [ci/knowledge-check.yml](ci/knowledge-check.yml) — without the last one, a PR that only deletes union lines skips the check).

## Concurrency

- **Multiple sessions, one machine**: the generator's write mode takes a directory lock (`docs/ai-knowledge/.gen-lock`, stale locks reclaimed after 60s), serializing concurrent memorize/init writes.
- **Multiple people, git merges**: onboarded repos get `merge=union` on **generated artifacts** (conflicts auto-concatenate; residue converges on regeneration; CI `--check` backstops), while knowledge source files keep default conflict behavior for `lore:resolve-merge` to merge semantically. The union entries themselves are generator-owned, backfilled line-by-line.
- **Shared files** (gotchas/contract): memorize appends via precise Edits, never full rewrites, so parallel sessions can't clobber each other.

## Day-to-day usage

Zero routine actions: write code normally; touching anchored paths pushes the relevant knowledge; substantial sessions get a wrap-up capture evaluation. The only manual actions: `/lore:memorize` (capture now), asking the agent about a convention (query), and telling the agent "this knowledge is stale" (trust-protocol correction).

Reviewing a knowledge file in a PR — three questions: Is the fact true? Does it have code-anchors? Is it underivable from the code? (Derivable → reject.)

## Metrics & privacy

All raw metrics are **local-only, zero telemetry**: events (gate fires, loads, verdicts, writes) append to `~/.claude/plugins/data/lore/metrics.jsonl` on your machine (`~/.codex/lore-data/metrics.jsonl` for Codex) — repo names, knowledge filenames, and session ids; never file contents. Nothing is uploaded anywhere, and nothing is shared with the team unless a repo explicitly opts in (next section). `/lore:stats` reads these files. Coverage caveat: loads are observed where the runtime exposes them (Claude Code: index/rules loads; Codex: path-push hits), and verdicts are collected only in sessions substantial enough to trip the Stop gate.

### Optional: team rollups (off by default)

Nothing is shared with the team unless the repo opts in. With `"teamMetrics": true` in `docs/ai-knowledge/lore.json`, memorize and knowledge-consolidate also refresh `docs/ai-knowledge/.metrics/<user>.json`, and it ships in the same PR as the knowledge.

- **What the file contains**: your git user name (or `LORE_METRICS_USER`), per-file counts for loads / used / ignored / contradicted / written over the last 90 days, gate-fire counts, and the export date. No session ids, no timelines, no knowledge content.
- **What it is for**: `/lore:stats` aggregates every committed rollup into a team section (most-used entries, entries ignored by everyone) and stops reporting an entry as "never loaded" once any teammate's rollup shows reads.
- **Off (the default)**: `export-summary` writes nothing and says so. Decide as a team before turning it on — in a public repository the rollups are public too.
- The files are generated artifacts: marked `linguist-generated`, write-gated against hand edits, rebuilt by each export.
### Cross-repo knowledge and team memory layers

lore is the **code-anchored** layer: knowledge that belongs to a repo, rides its PRs, and is pushed when you touch the code it describes. Facts that span repos (`scope: cross-repo`, `promote: pending`) should not pile up here — they belong in a team memory layer (a Hindsight / Mem0-style memory bank exposed over MCP, a shared knowledge repo, a wiki space). Name that layer in `lore.json` as `"promotionTarget"`, and `knowledge-consolidate` promotes pending entries there as compact durable facts, keeping the in-repo file as the anchored detail. The two layers are complementary, not competing: memory systems answer *when the agent asks*; lore answers *when the agent touches the code*.

## Cross-runtime (Codex)

The content layer (`docs/ai-knowledge/` + `AGENTS.md` pointers) is runtime-agnostic — any agent can read it. The engine currently ships for two runtimes:

- **Claude Code**: this plugin — skills + hooks + native path-scoped rules; the full experience.
- **Codex**: `bash codex/install.sh` — the same skills (as `lore-*` names in `~/.agents/skills`), the same gate scripts in codex mode, and a PostToolUse path-push that reuses the rules artifacts. Aligned with the codex-cli 0.144.x docs; that surface moves fast, so file an issue if a newer CLI misbehaves. Details: [codex/README.md](codex/README.md).

One runtime, one channel — don't double-install. Runtimes without the engine get read-only access, bounded by the generated gate files.

## Troubleshooting

Every lore hook fails open by design — a broken hook must never brick a session — which means a broken channel is silent. `/lore:doctor` makes it visible: dependency and layout checks, hook registration, data-dir writability, per-channel liveness from your metrics, dry runs of the write gate / Stop gate / path push against an isolated data dir, and the current repo's `--check` and index-scale status. Run it after installing, after upgrading Claude Code, and whenever `/lore:stats` shows a channel flatlining.

## Requirements

- macOS or Linux (bash 3.2+; Windows via WSL)
- `jq`, `git`, Node.js ≥ 18
- Multi-repo features (cross-repo anchors, cross-repo capture routing) assume sibling repos checked out under a common parent directory
- Verified against Claude Code as of 2026-08 and the codex-cli 0.144.x docs. Both surfaces move fast (slash-command/skill resolution and `${CLAUDE_PLUGIN_ROOT}` behavior have already shifted across versions) — if something misbehaves on a newer build, please open an issue.

## License

[MIT](LICENSE)
