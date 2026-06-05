You are running a structural review of the knowledge wiki at `${WORK_WIKI}`.

## Your job

Scan the wiki for **structural drift** that the cheap mechanical detectors can't fix on their own, then **apply every finding that meets the high-confidence gate below**. No proposals file. No pending review. Either you act on it this run, or you drop it and let it re-surface next run.

Read `${WORK_WIKI}/SCHEMA.md` first — it is the contract you are evaluating drift against.

## Inputs to gather

Run these — they cost nothing and emit JSON:

```bash
python3 ${WORK_WIKI}/.system/scripts/compress-recent-activity.py --json
python3 ${WORK_WIKI}/.system/scripts/detect-synthesis-rot.py --threshold-days 7 --json
python3 ${WORK_WIKI}/.system/scripts/detect-synthesis-rot.py --threshold-days 0 --json
```

Then read the actual pages that show up in those outputs (Read tool) before acting. Also read `${WORK_WIKI}/wiki/syntheses/refactor-intents.md` if it exists — that file holds SPLIT/DEDUP intents written by the synthesizer, and is the only thing that licenses action on those categories.

## Categories and the high-confidence gate

Seven categories. Only auto-apply when the per-category criteria below are met **in full**. If any criterion is uncertain, **drop the finding** — do not act, do not write a proposal, do not log it. It will reappear next run if still relevant.

The first six operate on `wiki/`. The seventh (STALE_WORKLOG) operates on the separate `worklog/` tree.

### RENAME (auto-applicable)
Apply only when:
- Explicit textual signal in a primary entity page (not in a transient session log fragment).
- Signal is past-tense or in-progress ("renamed", "is now") — NOT future-tense ("considering", "plan to", "should rename").
- `wiki/<dir>/<new>.md` does not exist.
- `wiki/<dir>/<old>.md` is canonical.
- You can name the exact `--type`/`--old`/`--new` invocation.

Action: `python3 .system/scripts/rename-entity.py --type <type> --old <old> --new <new>`

### RESOLVE (auto-applicable)
Apply only when:
- A specific entity page contains prose that explicitly resolves a synthesis item (in `decisions.md`, `open-questions.md`, or `recurring-bugs.md`).
- You can quote that prose verbatim, with file path + line range.
- The synthesis item maps 1:1 to the quoted prose — not "kind of related to."
- No conflicting prose elsewhere in the wiki.

Action: Edit the synthesis file to remove or close-out the item, citing the resolving page.

### ROT_FIX (auto-applicable)
Apply only when:
- A specific entity page is ≥7d newer than the synthesis.
- That entity page contains prose that directly updates / contradicts / supersedes a specific rotting item.
- You can quote both the old synthesis item and the new entity prose.
- The rewrite is a targeted single-item edit — NOT a structural rewrite of the synthesis page.

If the relationship is "topic touched" rather than "item directly updated/superseded", **drop**.

Action: Edit the synthesis item to reflect the new state, citing the entity prose.

### TRIM (auto-applicable)
Apply only when:
- A page's `## Recent activity` section has > 12 entries.
- At least 3 of those entries are older than the current month.

Action: Mechanical — delete oldest entries, keep newest 10. Never rewrite bullet content.

### SPLIT (auto-applicable only with a marker)
The mechanical signals (page > 250 lines, sub-entity mentions in Recent activity) cannot underwrite a SPLIT — they don't answer "where does the boundary go." The only thing that can is an **explicit textual intent** captured by the synthesizer from a live session. Check `${WORK_WIKI}/wiki/syntheses/refactor-intents.md` for entries under `## SPLIT`.

Apply only when ALL of:
- An entry exists under `## SPLIT` in `refactor-intents.md`.
- The entry's **Confidence** is `high`.
- The entry names exact `## <header>` blocks in the source page (not "the observability part" or "everything about X").
- Every named `## <header>` exists verbatim in the source page.
- The target result slug(s) do not yet exist as wiki pages.
- The split is a clean partition: each named header belongs to exactly one result page.

Action:
1. Create each target page with the moved section bodies, plus minimum required frontmatter (`type`, `slug`, `created: ${DATE_STR}`, `updated: ${DATE_STR}`).
2. Remove the moved sections from the source page; refresh its `updated:`.
3. Rewrite inbound markdown links across `wiki/**/*.md` that pointed at the moved sections — anchor links like `source.md#section` become `target.md#section`.
4. Remove the consumed entry from `refactor-intents.md`.

Hard cap: **1 SPLIT per run** (high blast radius). Counts toward the 5-action total.

### DEDUP (auto-applicable only with a marker)
Same shape as SPLIT: mechanical overlap detection can't pick canonical. Check `refactor-intents.md` for entries under `## DEDUP`.

Apply only when ALL of:
- An entry exists under `## DEDUP` in `refactor-intents.md`.
- The entry's **Confidence** is `high`.
- The entry names: a canonical page path, a target page path, and the exact `## <header>` on the target that gets replaced.
- The named canonical page exists and contains coverage of the topic.
- The named target section exists verbatim on the target page.
- The replacement instruction is a single link (e.g., `See [azure-deployment](../technologies/azure-deployment.md#supervisord-setup).`).

Action:
1. Replace the named target section's body with the replacement link (keep the `## <header>` line so existing anchor links don't break, or update inbound anchors if the entry says to).
2. Refresh the target page's `updated:`.
3. Remove the consumed entry from `refactor-intents.md`.

Hard cap: **1 DEDUP per run**. Counts toward the 5-action total.

**For both:** if any criterion fails, **leave the marker in `refactor-intents.md`** — don't act, don't delete the entry. The marker persists until either a later run's gate passes or a human resolves it. Markers that survive ~30 runs (the pass runs daily) are a signal the intent was insufficient; consider hand-resolving.

### STALE_WORKLOG (auto-applicable — operates on `worklog/`, not `wiki/`)
The worklog (`${WORK_WIKI}/worklog/`) tracks in-flight workstreams; see `${WORK_WIKI}/worklog/WORKLOG.md`. Live items that go idle without a completion signal should be flagged so the board reflects reality — but **not** archived, since idleness is ambiguous (a workstream may be parked, not done).

Gather: `Glob worklog/live/*.md`, read each item's `updated:` frontmatter.

Apply only when:
- The item lives in `worklog/live/` (not `archive/`).
- Its `updated:` date is **more than 14 days** before today (${DATE_STR}).
- Its `status:` is not already `stale`.

Action (purely mechanical, per qualifying item):
1. Set `status: stale` in the item's frontmatter (leave `updated:` unchanged — staleness is about inactivity, don't reset the clock).
2. Update its line in `worklog/board.md` to `[stale]`.

Do **not** archive, rewrite Status, or delete stale items — only mark. This category is mechanical and does **not** count toward the 5-action `wiki/` cap; apply it to all qualifying items.

## Execution

1. Read SCHEMA.md, run the detector commands, list flagged pages, read them. Read `refactor-intents.md` if it exists.
2. Enumerate candidate findings. Tag each with category and your confidence.
3. **Apply** each finding that meets the gate above. Hard caps:
   - Maximum **5 auto-applied actions per run**. Pick the strongest 5; drop the rest.
   - Never apply two actions to the same file in one run.
   - No chained auto-applies (each action stands alone).
   - At most 1 SPLIT and 1 DEDUP per run (in addition to the 5-action cap).
4. **One-time cleanup:** if `wiki/syntheses/refactor-proposals.md` exists from the legacy flow, `rm` it — it is no longer maintained.

That is the entire output. **Do not write a proposals file. Do not write a log file. Do not summarize.** The shell script (`refactor-review.sh`) will detect what you modified, commit it, and push.

## Discipline

- **The cost of a missed action is one week; the cost of a wrong action is a git revert plus loss of trust.** When in doubt, drop.
- **No COMPRESS actions** — handled post-synth by `.system/scripts/auto-compress-touched.sh`.
- **No upstream code repo reads.** Wiki refactors only.
- **No stylistic changes.** No "rename for clarity," no "this should be a concept not a project."
- **No fabricated evidence.** Every action must cite specific prose.
- Your write targets are only the auto-apply edits described above: `wiki/` for the first six categories, and `worklog/live/*.md` + `worklog/board.md` for STALE_WORKLOG only. Never modify anything in `${WORK_WIKI}/.system/` or elsewhere.
