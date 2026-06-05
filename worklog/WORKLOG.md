# Worklog Schema

This file is the contract for the **worklog** — the transient, in-flight layer of the system. It is the companion to [`../SCHEMA.md`](../SCHEMA.md), which governs the durable `wiki/`. The maintainer (LLM) reads this file before every worklog edit.

## Purpose

The wiki answers **"what is true and durable."** The worklog answers **"what am I working on right now, and what's the next step to resume it."**

The durable wiki (`wiki/`) deliberately excludes transient state — in-progress branches, today's todo, "waiting on review." That state still matters for resuming work, so it lives here instead. **The worklog is the one place transient/in-flight state is allowed.** It never lives in `wiki/`.

The worklog is **maintained by the same machinery as the wiki**: the batched synthesizer reads session transcript tails and, in a separate pass, updates the worklog (see the "Worklog" section in `.system/prompts/wiki-synthesize-pending.md`). A separate PR-state poller (`.system/scripts/pr-state-sync.sh`) keeps GitHub PR state current between synth runs.

## Layout

```
worklog/
  WORKLOG.md            # this contract
  board.md              # one line per ACTIVE workstream — the scannable index
  live/<slug>.md        # one file per active workstream (in flight)
  archive/<slug>.md     # completed workstreams, git mv'd out of live/
```

## What is a workstream

A **workstream** is one coherent thread of in-flight work — a PR, a ticket, a named branch, or a focused investigation. It is finer-grained than a project: one project can have several concurrent workstreams.

Key each workstream by the most stable identifier available, in priority order: **ticket → PR → branch → topic**. The slug is lowercase kebab-case (same convention as the wiki) and is the filename: `worklog/live/proj-123-fix-retry-logic.md`.

## Live-item shape (`worklog/live/<slug>.md`)

```
---
type: workstream
slug: <slug>
status: active | blocked | waiting | stale
created: <YYYY-MM-DD>
updated: <YYYY-MM-DD>
keys: [PROJ-123, PR#456, branch:fix-retry-logic]   # identifiers this item is keyed by
project: <wiki project slug>     # optional; cross-links to wiki/entities/projects/<slug>.md
---

# <Workstream title>

**Next action:** <the single concrete step to resume — one sentence>
**Blockers:** <what's blocking, or "none">

## Status
<2–4 lines of current state. OVERWRITE on each update — this is current state, not a diary.>

## PR state
<!-- managed by pr-state-sync.sh — do not hand-edit -->
<one line: state (open/draft/merged/closed) · CI · review · mergeable · last synced YYYY-MM-DD>

## Links
- PR / Ticket / exec-plan URLs
- Wiki: [<project>](../../wiki/entities/projects/<slug>.md)   # link INTO the wiki, never mirror it
```

`status` values for **live** items: `active`, `blocked`, `waiting` (on someone/something else), `stale` (idle, see archival). `merged`/`closed`/`done` are terminal and belong on archived items.

The `## PR state` block is owned by `pr-state-sync.sh`; the synthesizer and humans should not hand-edit it. It is absent on workstreams with no associated PR.

## Board shape (`worklog/board.md`)

A flat list, **one line per live item**, most-recently-touched first. Format:

```
- [status] <slug> — <next action> ([detail](live/<slug>.md))
```

Hard rules: one line per item, no sub-bullets, no embedded newlines. The board is an index — detail lives in the per-item file. Cap ~40 live items; if exceeded, the oldest `stale` items are candidates for archival.

## Update rules

When folding a transcript tail (synthesizer) or polling PRs (poller):

1. Read this file first.
2. **Create** a live item when active, not-yet-complete work on an identifiable workstream appears (a PR pushed, a ticket worked, a named branch, a focused investigation). Search `live/` and `archive/` by key/slug first; prefer updating an existing item to creating a duplicate.
3. **Update** by overwriting Status and Next action with the current picture — do **not** append a running diary. Refresh `updated:`. Add new Links. Flip `status:` to `blocked`/`waiting` when a blocker appears.
4. Keep `board.md` in sync on every create / update / archive.
5. **Do not duplicate the wiki.** Link into wiki pages; never mirror durable facts here. If something is durable (a decision, a recurring pattern, an entity fact), it belongs in `wiki/`, not here.
6. If a tail shows no active workstream and touches no existing live item, write nothing.

## Archival

A workstream leaves `live/` and moves to `archive/` via `git mv live/<slug>.md archive/<slug>.md`, and its board line is removed.

- **Completion-driven (primary):** on an explicit completion signal — "merged", "shipped", "done", "closing this out", a PR merged/closed, an investigation concluded. Apply the **tomorrow test** on archival: keep only what would help understand the outcome later; strip in-flight noise. Set a terminal `status:` (`merged`, `closed`, `done`) and record the outcome in one line.
- **Idle-driven (secondary):** the daily refactor-review marks a live item `stale` on the board when `updated:` is older than 14 days with no completion signal. Stale items are **not** auto-archived — idleness is ambiguous (a workstream may be parked).

## Discipline

- **Current state, not history.** Overwrite; don't append. The git log is the history.
- **One line on the board, ≤80 lines per live item.** Status section ≤4 lines.
- **No invented facts.** Only what the transcript / `gh` output supports.
- **Link, don't mirror.** Especially: never copy durable wiki content here.

## Recall

To recall in-flight work, open [`board.md`](board.md). The `SessionStart` hook (`.system/hooks/wiki-session-start.sh`) injects the project-filtered board into new sessions automatically.
