---
name: init
user-invocable: false
description: One-shot onboarding of the current repo to the AI knowledge base (create the docs/ai-knowledge/ skeleton, CLAUDE.md/AGENTS.md pointers, .claude/settings.json marketplace config, and guide seeding). Use when the user says "onboard the knowledge base", "knowledge init", "set up a knowledge base for this repo", "enable lore". NOT for day-to-day capture in already-onboarded repos (use memorize).
---

# init — onboard a repo to the knowledge base

Create the knowledge-base skeleton for the current repo. The existence of `docs/ai-knowledge/` is itself the opt-in marker — once it exists, this plugin's Stop gate and rules pushing activate for the repo.

## Steps

1. **Idempotency guard**: if `docs/ai-knowledge/` already exists, report "already onboarded" and only backfill missing pieces (pointer lines, settings; `.gitattributes` entries and the gate files are backfilled item-by-item by step 5's generator). Never overwrite existing files.

2. **Create the directory and first files** (`docs/ai-knowledge/` is guarded by a PreToolUse gate; invoking this skill auto-issued the grant for this turn — no manual step needed):
   - `docs/ai-knowledge/archive/.gitkeep`
   - `docs/ai-knowledge/lore.json` — `{"language": "<tag>"}`; ask the user which language knowledge should be written in (BCP 47 tag; default `en`). Write the contract/gotchas bodies below — and all seeded entries — in that language (frontmatter keys and enum values stay English).
   - `docs/ai-knowledge/contract.md` — use the template below, filled from the repo's actual public interface (API schema, package entry points, service endpoints, module-federation config — whatever applies): what this repo exposes, who consumes it, change impact, release constraints. **Write only what CLAUDE.md does not already say** — CLAUDE.md is loaded every session; restating the tech stack / directory layout / dependency lists in contract.md means it gets read every time with zero new information (measured: contracts padded this way were ignored more often than used). Where CLAUDE.md already maps the landscape, contract.md adds only the hard contract details (endpoint paths / ports / error mapping / auth guards / upload limits / release ordering — the facts you reach for when debugging).
   - `docs/ai-knowledge/gotchas.md` — from the generic template; 1–2 known pitfalls is a fine start. No reliable source → leave the template comments; never fabricate.
   - The repo root `.gitattributes` union entries for generated artifacts **need no manual writing**: step 5's generator detects/backfills them line-by-line (works on already-onboarded repos too; `--check` reports missing lines as drift). Principle: union-merge only **generated artifacts** (INDEX, gate AGENTS.md/CLAUDE.md, rules — idempotently rebuildable; duplicate residue converges on regeneration); knowledge source files keep default conflict behavior for resolve-merge to merge semantically — plain-text auto-union would bypass "conservative status, semantic dedupe".

3. **Pointer lines**:
   - `CLAUDE.md`: insert at the top of the file (outside any generator-managed block):

     ```markdown
     ## Knowledge base

     @docs/ai-knowledge/INDEX.md

     > Knowledge is a lead, not the source of truth — verify against the code via each file's code-anchors before key decisions; when knowledge contradicts code, the code wins and the knowledge file gets fixed in passing. Learned a new business fact while finishing a task → invoke lore:memorize. Agents without that skill must not write docs/ai-knowledge/ directly (write policy: see that directory's AGENTS.md).
     ```

   - `AGENTS.md` (create if missing): append this section:

     ```markdown
     This repo maintains an AI knowledge base: before starting any task that touches business logic, read `docs/ai-knowledge/INDEX.md` and open only the entries that match.

     - Knowledge is a lead, not the source of truth — verify against the code via each file's code-anchors before key decisions; when knowledge contradicts code, the code wins, and fix the knowledge file in passing.
     - If you learned a "fact you cannot derive from the code" while finishing a task: capture it only if the lore engine is installed (Claude Code: lore:memorize; Codex: the installed lore-memorize). **Agents without those skills must not write `docs/ai-knowledge/` directly** — put candidate knowledge in the PR description or tell the user. Write policy: `docs/ai-knowledge/AGENTS.md`.
     - Knowledge changes ride normal code PRs; at most 2 knowledge files per PR.
     ```

4. **settings**: merge (never overwrite) into `.claude/settings.json`, so teammates opening the repo get an install prompt. Resolve the marketplace source at runtime: find the marketplace that provides the currently running lore plugin (read `~/.claude/plugins/known_marketplaces.json`, or run `claude plugin marketplace list`) and copy its name and its `source` object **verbatim** — source forms vary (git/url, github/repo, directory); do not synthesize one:

   ```json
   {
   	"extraKnownMarketplaces": {
   		"<marketplace-name>": {
   			"source": <the marketplace's source object, copied verbatim>
   		}
   	},
   	"enabledPlugins": {"lore@<marketplace-name>": true}
   }
   ```

   If the marketplace source cannot be resolved, skip this step and say so in the report.

5. **Generate the index** (`<engine-scripts>` = the absolute scripts path injected into context when this skill was invoked — the line starting `lore engine scripts:`; on Codex the installer bakes the real path in): `node "<engine-scripts>/gen-knowledge-index.mjs" <repo-root>`. Besides INDEX.md and rules, it also emits the directory write-gate files `docs/ai-knowledge/AGENTS.md` + `docs/ai-knowledge/CLAUDE.md` (generated — never hand-edit).

6. **Guided seeding (critical — prevents a cold, empty start)**: ask the user 2–3 questions — "What pitfall bites people most in this repo?", "Which conventions must a newcomer/AI know that the code doesn't show?", "Any existing impact-analysis or debugging docs worth harvesting?" — write the answers as the first knowledge entries per the memorize file spec (with provenance), then rerun the generator.

7. **Report**: list the files created + remind the user: seed a few real entries before relying on automatic capture; knowledge changes are reviewed in code PRs.

## contract.md template

> When adapting the description to this repo, keep it in "symptoms / concrete scenarios" form. Never write a "read before changing X" catch-all — a description that matches every session only gets ignored.

```markdown
---
name: contract
description: Read when debugging "a consumer breaks after a deploy/release", "missing or renamed export/endpoint", "schema or payload drift", "version mismatch between this repo and its consumers"; read before changing a public interface (exported API, endpoints, schema, events, shared-dependency contracts) — change impact and release constraints live here
scope: repo
code-anchors:
  - <path(s) to the files that define the public interface: API schema, package entry point, service route table, module-federation config, …>
status: fact
provenance: repo config + build/release setup
env: all
promote: n/a
updated: <today>
---

## What this repo exposes
<!-- endpoints / exported APIs / published packages / federation exposes — item + one-line semantics -->

## Who consumes it
<!-- downstream repos/services and what they use it for -->

## What this repo consumes
<!-- upstream services, shared packages, remotes -->

## Change impact & release constraints
<!-- e.g. renaming an export requires grepping all consumers; release ordering; codegen consumers must rerun -->

## Gotchas
```

## gotchas.md template

```markdown
---
name: gotchas
description: Known pitfalls and anti-knowledge for this repo — skim before starting changes; read when hitting "looks like it should work but doesn't" behavior
scope: repo
code-anchors: []
status: fact
provenance: team experience
env: all
promote: n/a
updated: <today>
---

## Pitfalls (symptom → cause → correct approach)

## Anti-knowledge (the model tends to assume X; the truth is Y)
```
