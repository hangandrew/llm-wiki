You maintain the **worklog** at `${WORK_WIKI}/worklog/`. The PR-state poller detected structural PR events and is handing them to you. Your job is narrow: **create live items for new PRs** and **archive items for merged/closed PRs**. Do nothing else.

## Read this first

`${WORK_WIKI}/worklog/WORKLOG.md` — the contract (live-item shape, board format, archival rules). Follow it exactly.

The worklog is the transient/in-flight layer. It is **separate from `wiki/`** — never write to `wiki/` from this job, and never mirror durable wiki facts into the worklog. Link into the wiki instead.

## Run context

- Date: ${DATE_STR}
- The poller already refreshed the `## PR state` block on existing tracked items. **Do not touch `## PR state` blocks** — they are poller-owned.
- Do **not** run `git commit` — the poller commits after you finish.

## New PRs (create a live item for each)

For each PR below that does not already have a live item (search `worklog/live/` and `worklog/archive/` by PR number / branch first), create `worklog/live/<slug>.md` per WORKLOG.md:
- Slug: kebab-case, keyed ticket → PR → branch → topic. Prefer a ticket id if the PR title/body names one (e.g. `PROJ-123`), else the PR number + a short topic (e.g. `pr-456-fix-timeout`).
- Frontmatter: `type: workstream`, `status: active`, `created`/`updated: ${DATE_STR}`, `keys:` including `PR#<number>` and `branch:<headRefName>` (and any ticket id you find), `project:` set to the matching `wiki/entities/projects/<slug>` if one obviously applies (else omit).
- Body: a one-line **Next action** inferred from the PR title/body (e.g. "address review comments", "get CI green", "await review"), **Blockers:** none unless stated, a 2–4 line **Status** summarizing what the PR does, and a **Links** section with the PR URL (+ ticket/wiki links if clear).
- Add one line to `worklog/board.md`.

Keep it light — the synthesizer will deepen these from session transcripts later. Do not invent detail not supported by the PR.

${NEW_PRS_BLOCK}

## Merged / closed PRs (archive the tracked item)

For each item below, `git mv worklog/live/<slug>.md worklog/archive/<slug>.md`:
- Set a terminal `status:` (`merged` if merged, `closed` if closed-unmerged), refresh `updated: ${DATE_STR}`.
- Apply the **tomorrow test**: trim in-flight noise; keep a one-line outcome ("Merged <date>." / "Closed unmerged.") and the links.
- Remove the item's line from `worklog/board.md`.
- If the PR produced something genuinely durable worth a wiki note, **do not** write it here — the wiki synthesizer handles that from transcripts. Stay in `worklog/`.

If a referenced item file does not exist in `worklog/live/` (already archived or never created), skip it.

${CLOSED_BLOCK}

## Rules

- Only touch `${WORK_WIKI}/worklog/`. Never modify `wiki/` or `${WORK_WIKI}/.system/`.
- Never edit `## PR state` blocks.
- No commit. The poller commits your changes.
- If both lists are empty, do nothing.
