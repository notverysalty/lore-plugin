---
name: resolve-merge
user-invocable: false
description: Semantically resolve git merge conflicts in knowledge-base files (when docs/ai-knowledge/ or .claude/rules/knowledge/ shows <<<<<<< conflict markers after merge/rebase/cherry-pick). Knowledge is additive → default to union, never drop entries; generated artifacts INDEX/rules are never hand-resolved — rerun the generator to converge. Use when (a) the user runs /lore:resolve-merge or says "resolve the knowledge conflicts / the knowledge base has merge conflicts"; (b) conflict markers appear in the knowledge base after git merge/rebase. NOT for monthly governance of semantic contradictions between entries (knowledge-consolidate) or knowledge-vs-code contradictions (the code wins; fix the knowledge).
---

# resolve-merge — semantic merge for knowledge-base git conflicts

When two branches' changes to the same knowledge file collide in merge/rebase, **merge semantically as a union** instead of git's pick-a-side — knowledge is additive; picking one side = dropping a real piece of knowledge.

**First principle: never lose knowledge.** When unsure, keep both sides and annotate; never silently drop an entry.

## Applicability (confirm first, otherwise do nothing)

- Only when the worktree **already shows conflict markers** (`git status` shows `UU` / both modified). No conflicts → say "no conflicts" and stop.
- Touch only `docs/ai-knowledge/` and `.claude/rules/knowledge/`; leave other conflicted files to the user or their own flows.
- Distinct from `knowledge-consolidate` (proactive monthly governance of semantic contradictions) and from "knowledge contradicts code — fix the knowledge" (that's a content fix).

## Step 1: Identify and classify conflicted files

```
git diff --name-only --diff-filter=U -- docs/ai-knowledge/ .claude/rules/knowledge/
```
Classify by the **generated-artifact allowlist** first: `INDEX.md`, the gate files `AGENTS.md` / `CLAUDE.md` under `docs/ai-knowledge/`, and everything under `.claude/rules/knowledge/*.md` are **generated** → step 3 (rebuilding; hand-merging them is forbidden). The remaining `docs/ai-knowledge/*.md` are **knowledge files** → step 2 (semantic merge).

## Step 2: Knowledge files — semantic union merge

> Write authorization: `docs/ai-knowledge/` is guarded by a PreToolUse gate; invoking this skill auto-issued the grant (bounded uses, cleared at Stop, short-TTL backstop).

Read each conflict's three sections (`<<<<<<< ours` / `=======` / `>>>>>>> theirs`) and merge into a marker-free result:

- **Body**: keep **all** facts/pitfalls/entries added on either side (union); merge two entries into one only when they are **semantically duplicate** (keep the richer one).
- **Frontmatter**:
  - `updated` → the **newer** date
  - `code-anchors` / `related` → **union**, deduped
  - `status` → the **conservative** value (either side `hypothesis` → `hypothesis`)
  - `description` → merge both sides' symptom keywords (union — don't lose retrieval terms)
  - `provenance` → keep both sources (note this merge)
  - `scope` / `env` / `promote` → keep if identical; on conflict take the conservative value and flag for human review in the body
- **Unsure** → keep both sections, insert `<!-- ⚠️ merge kept both versions, needs human confirmation -->`, and downgrade `status` to `hypothesis`.

## Step 3: Generated artifacts — never hand-resolve; rerun the generator

Repos with the `.gitattributes` union entries (maintained line-by-line by the generator) usually won't show conflict markers in artifacts — instead you get **duplicate/mis-ordered residue lines** (e.g. the same index entry twice). That is not a conflict: skip to item 3 below and regenerate (CI `--check` also catches this drift).

`INDEX.md`, the gate files `docs/ai-knowledge/{AGENTS,CLAUDE}.md`, and `.claude/rules/knowledge/*.md` are generated — **never hand-merge their conflict markers**:
1. Finish merging all knowledge files (step 2) first.
2. For artifact conflicts, take either side to clear the markers (`git checkout --ours <file>` is fine) — it gets overwritten next.
3. Rerun the generator (idempotent full rebuild, converges to correct; `<engine-scripts>` = the injected absolute scripts path — the `lore engine scripts:` line):
   `node "<engine-scripts>/gen-knowledge-index.mjs" <repo-root>`

## Step 4: PII / secrets self-check

Sweep the merged result: no real emails / phone numbers / order or tracking numbers / tokens / keys / cookies; examples use placeholders.

## Step 5: Wrap up (no auto-commit)

1. `node "<engine-scripts>/gen-knowledge-index.mjs" <repo-root> --check` — confirm zero dead anchors, zero drift.
2. **Never `git add` / `commit` automatically** — merging is high-risk; the user reviews, then stages and continues the merge/rebase.
3. Give a one-line merge rationale per file, and end the reply with:

```
---
✅ Done: resolved N knowledge-file conflicts (union X entries / merged Y duplicates / Z flagged) + rebuilt INDEX and rules
⏭️ Next: review the merge result → git add → continue merge / rebase
🧠 lore: <list of merged files>
⚠️ Needs human confirmation: <files where both versions were kept; delete this line if none>
---
```

## Hard rules

- **Never lose knowledge**: union first; keep both versions and annotate when unsure.
- Touch no conflicted files outside the knowledge base.
- No auto-commit (the user reviews, then continues the merge).
- Artifacts are only rebuilt, never hand-resolved.
