---
description: Check that the lore engine is wired up (hooks, data dir, dry-run gates) and that this repo is healthy
---

Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/lore-doctor.sh"` (on Codex: `bash ~/.codex/lore/scripts/lore-doctor.sh codex`) and report its output.

Why this exists: every lore hook fails open by design, so a broken channel is silent — knowledge quietly stops being pushed, captured, or measured. The doctor checks dependencies, the engine layout, hook registration, data-dir writability, per-channel liveness (last event per event type), then DRY-RUNS the write gate / Stop gate / path push against an isolated data dir, and finally reports the current repo's `--check` status and index scale.

Interpretation: ✖ lines are real breakage — act on them first (a missing hook registration or a failed dry run means the plugin build or the runtime changed). ⚠ lines are advisory: "never recorded" channels are normal on a fresh install; "approaching threshold" means the index will switch to grouped mode soon (tune via `lore.json`). End with a one-line verdict and at most 3 concrete fixes.
