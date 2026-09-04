---
description: Show lore metrics (capture funnel / read effectiveness & trend / polish candidates / ⚠️ contradiction follow-up / inventory)
---

Run the lore metrics summary and interpret it: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/lore-stats.sh"` (on Codex the script lives at `~/.codex/lore/scripts/lore-stats.sh codex`). Add `--since=YYYY-MM-DD` to window the event metrics (inventory scan and "never loaded" always use full history).

Then assess adoption health from the numbers:
- Capture funnel: low response rate → the gate instruction is being ignored (check the reason wording); written stuck at 0 → the gate fires but no capture habit has formed; a high nothing_to_save share is healthy (quality over quantity).
- Compacted mid-session: sessions whose context was compacted before they ended. If their nothing_to_save share sits well above the overall funnel, early-session facts are being lost at wrap-up — the post-compaction nudge exists for this; in long sessions, capture mid-way.
- Gate fires too rarely → thresholds may be too strict, or sessions aren't running in onboarded repos; too often → noisy, consider raising thresholds.
- Top loaded knowledge → most-hit entries; the "never loaded" list → retire-or-activate candidates.
- Feedback trend: if the last-14-days hit rate is clearly below the historical rate, new feedback quality is slipping — don't be comforted by the cumulative number; find the culprits in the polish-candidates list.
- Polish candidates (ignored ≥ 2 and > used) → retrieved but not helping; each carries a ↳ prescription (directory anchor / catch-all description / bundled topics / oversized) — hand those to knowledge-consolidate.
- Anchor drift (anchored code committed after the entry's `updated` date, ranked by commit count) → the file is still there but moved on; the top entries are the first to re-verify.
- ⚠️ Contradicted follow-up + loop state: ✖ still-unresolved entries deserve priority verification and supersede/downgrade; ✔ re-used means the loop closed. This feeds the monthly consolidate.
- Team rollups: event sections above are this machine only — this section aggregates every committed `docs/ai-knowledge/.metrics/<user>.json`. "Ignored by everyone" is the strongest polish/retire signal there is; no rollups committed → the repo has not opted in (`"teamMetrics": true` in `docs/ai-knowledge/lore.json`, a team decision); once it has, memorize/consolidate refresh them automatically.
- Inventory: the longer `promote: pending` piles up, the more overdue the harvest; cross-repo anchor count reflects adoption; long time-to-first-use → new knowledge isn't reaching the retrieval surface.

Finish with a one-sentence verdict + at most 3 actionable suggestions.
