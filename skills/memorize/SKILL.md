---
name: memorize
user-invocable: false
description: Persist business knowledge learned this session into the repo knowledge base (docs/ai-knowledge/). Use when (a) the Stop gate [lore wrap-up check] asks you to evaluate this session; (b) the user runs /lore:memorize or says "remember this", "save this to the knowledge base", "worth keeping"; (c) you just confirmed a business fact, cross-repo convention, pitfall, or piece of anti-knowledge that cannot be derived from the code and should persist. NOT for transient task state, code-structure notes, or unverified guesses.
---

# memorize — capture business knowledge

Write the "facts you cannot derive from the code" learned this session into the owning repo's `docs/ai-knowledge/` (default: the current repo; cross-repo routing in step 4). Knowledge ships in normal code PRs and gets human review.

**Quality over quantity is the first principle**: if nothing qualifies, reply with one line — "nothing to save (reason)" — and finish normally. That outcome is legitimate and encouraged. A wrong or mediocre memory is worse than no memory.

Precondition: if the current repo has no `docs/ai-knowledge/`, ask the user whether to onboard (run lore:init). Do not create it on your own.

## Step 1: Is it worth saving? (rubric)

Save only facts that meet **all three**: ① a business/architecture-level fact or constraint; ② not derivable from the current code, config, or schema; ③ reusable by future sessions.

Positive examples (save):
- "Only one active subscription is allowed per webhook event type" — implicit business rule; the code only shows a backend 409
- "Changing the shared DateRangePicker requires re-verifying the three product wrappers that embed it" — cross-repo impact convention
- "Updating canvas state directly inside the drag handler janks rendering; go through the store's debounced sync" — pitfall + cause
- "The model tends to assume X, but the truth is Y" — **anti-knowledge**; every caught AI mistake is worth one entry

Negative examples (reject):
- "The board editor lives in src/features/boardEditor/" — code structure, grep-able
- "Which fields the orders endpoint returns" — the schema is the source of truth
- "This session changed 3 files to fix a bug" — task state; belongs to git history / planning docs
- The repo's tech stack / directory layout / common commands / upstream-downstream list — CLAUDE.md is loaded every session and already says this; restating it in the knowledge base = read every time, zero new information (knowledge covers only what CLAUDE.md does not)
- Unverified mid-debugging guesses — if you must record one, mark it `status: hypothesis`

## Step 2: Harvest personal auto-memory

If `~/.claude/projects/<current project>/memory/MEMORY.md` exists, scan it: fold **team-level** business facts into this capture (leave personal preferences and personal environment notes alone). Trust order: code > team knowledge base > personal memory.

## Step 3: Dedupe (update beats create)

Read `docs/ai-knowledge/INDEX.md`, then read the likely-related files. If the topic already exists → update that file (fix errors, add facts, refresh `updated`); do not create a duplicate. One topic, one file.

**A "topic" is bounded by symptom family, not module name**: if the new fact merely shares a module/feature name with an existing file but has different trigger symptoms → split into a new file and cross-link via `related`; do not append. Split signals (any one hit means split): the description already lists 3+ unrelated symptoms; the body would exceed 150 lines after the append. Once a file snowballs into a multi-topic digest, any single symptom match pushes the whole file at the agent, and every other topic is noise for that session (measured: such digest files get ignored nearly twice as often as used).

## Step 4: Scope routing (where does it land?)

Ask first: **"whose code change would invalidate this fact?"** That repo = the owning repo. Principle: **knowledge follows the code** — land it in the repo whose code it describes, with locally resolvable anchors.

1. **Owning repo = current repo** → write here, `scope: repo`.
2. **Owning repo = a sibling repo that is locally reachable** (same-named directory under the parent dir, with its own `docs/ai-knowledge/`) → **write directly into the owning repo's** `docs/ai-knowledge/<name>.md`, `scope: repo`, anchors pointing at that repo's own code; then run step 7's generator against **that repo**. ⚠️ A cross-repo write is not part of this session's PR — the wrap-up must tell the user "knowledge landed in repo `X`; commit it there separately."
3. **Multi-owner / topology-level** (3+ repos, a cross-repo business chain, release ordering), **or the owning repo is not locally reachable** (foreign upstream service, not cloned) → write it in the **current repo** as the design anchor point, `scope: cross-repo` + `promote: pending`, first paragraph naming the owning repo(s); reference reachable foreign code with **cross-repo anchors** `repo-dir-name:path` (the generator validates reachable siblings and skips unreachable ones); the monthly knowledge-consolidate harvests these. If the topology cleanly splits into per-repo slices, land the slices per rule 2 and keep the global topology here as the source of truth.
4. **A change in what this repo exposes / who consumes it** → write to or update `contract.md`.

## Step 5: PII / secrets self-check

Never write: real customer emails/phone numbers/order or tracking numbers, tokens/keys/cookies, internal URLs with sensitive parameters. Examples always use placeholders (`user@example.com`, `ORDER_ID`).

## Step 6: Write to disk

> Write authorization: `docs/ai-knowledge/` is guarded by a PreToolUse gate, but **invoking this skill auto-issues the grant** (bounded uses, cleared at Stop, short-TTL backstop); you cannot and need not obtain it manually. If a write is denied, the turn's grant is exhausted or expired — invoke this skill again; do not work around the gate.

**Language**: if `docs/ai-knowledge/lore.json` exists and sets `"language"`, write the knowledge body and `description` in that language; otherwise write English. Frontmatter keys and enum values (`status: fact`, `scope: repo`, …) are always English.

One topic per file, within 100–200 lines, kebab-case filename, placed in the **target repo** (per step 4) at `docs/ai-knowledge/<name>.md`:

```markdown
---
name: <unique kebab-case name>
description: <when to read me — write symptom words / error keywords / module aliases, not just concept names. Negative self-test: a phrasing most everyday changes in this repo would match ("read before changing X", "read when touching Y") is too broad — it gets pushed at every session and then ignored; narrow it to concrete symptoms/errors/scenarios>
scope: repo | cross-repo
code-anchors:               # anchors ARE the push triggers: editing a matched file force-pushes this entry; anchor to the specific files that carry the fact
  - src/x/theContract.ts    # prefer specific files; anchors are pointers, never pasted code
  - src/path/to/dir/        # a directory anchor (trailing /) pushes this entry for ANY change under it — use only when that is truly warranted; never on hot top-level dirs (editor roots, core services)
  - sibling-repo:src/x.ts   # cross-repo anchor (multi-owner knowledge): repo name = sibling directory name under the parent dir
related: [<names of other knowledge files>]
status: fact | hypothesis    # new knowledge defaults to hypothesis; human review promotes it to fact
provenance: <source: session conclusion summary / ticket link / human confirmation>
env: testing | prod | all
promote: pending | done | n/a
updated: <YYYY-MM-DD, today>
---

## Background (why the design is what it is)
## Key business facts (not derivable from code)
## Gotchas
## Code entry points
```

**Incident/bug root-cause entries**: when the fix has already landed, open the body with "fixed + where the defense lives", narrow the description to the exact error fingerprint (recurrence presupposes the defense failing), and anchor to the defense code — never to the module's hot file (e.g. a core service), or every unrelated change keeps pushing a solved incident (measured: one such entry was pushed 13 times with 0 hits).

**Concurrency rule**: when updating an existing knowledge file (especially shared ones like gotchas.md / contract.md), use **precise Edit appends** (locate the insertion point by existing text); never rewrite the whole file — parallel sessions capturing at the same time would silently clobber each other's fresh entries. A failed Edit match is itself the conflict detector.

## Step 7: Rebuild index + wrap up

1. Run the generator once for **every repo written to** (step 4 may have landed files in a sibling repo — run it there too). `<engine-scripts>` below = the absolute scripts path injected into context when this skill was invoked (the line starting `lore engine scripts:`); on Codex the installer bakes the real path in. Never guess or search for another copy:
   `node "<engine-scripts>/gen-knowledge-index.mjs" <repo-root>`
   This produces/updates that repo's `docs/ai-knowledge/INDEX.md` and `.claude/rules/knowledge/*.md`.
2. Capture telemetry (feeds the fire→capture conversion rate and time-to-first-use in /lore:stats): run once per **written/updated knowledge file**:
   `bash "<engine-scripts>/record-write.sh" written <filename.md> <session_id>`
   For cross-repo writes use `repo-dir-name:filename.md` to tag the owning repo; copy session_id verbatim from the gate instruction's trailing quoted value; omit it when the user ran /memorize manually without a gate.
3. Refresh your per-user metrics rollup so team-wide stats ride the same PR (once per repo written to; it rewrites only your own `docs/ai-knowledge/.metrics/<user>.json`):
   `bash "<engine-scripts>/lore-stats.sh" export-summary <repo-root>`
4. Constraint: at most 2 knowledge files per PR; suggest splitting beyond that.
5. Do not commit — knowledge changes ride the same PR as code; the user decides when to commit.
6. **Keep execution lean**: no long narration of the process. End the reply with the wrap-up card at the very bottom (the status the user cares about must be the last thing on screen, preceded by `---`).

   **Three formatting rules (or it collapses into a wall of text)**: ① a blank line between each of the four items; ② multi-point items get indented sub-lists (`①②③` or `-`) on separate lines — never squeezed into one line with separators; ③ first sentence of each item stays crisp; details indent to following lines or move above the card — the card is a status glance, not the full report.

```
---
✅ Done: <one sentence; one line per item if several>

⏭️ Next: <one sentence; ①②③ on separate indented lines if several options>

🧠 lore: <captured N file(s), one filename per line / nothing to save (reason)>

⚠️ Possibly stale: <filename + one-line reason per entry; delete this line if none>
---
```

(The ⚠️ line closes the gate's feedback loop: if the session wrap-up judged a loaded knowledge file contradicted, name it here as input for knowledge-consolidate.)
