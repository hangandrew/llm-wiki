You are bootstrapping a knowledge wiki at `${WORK_WIKI}` from a corpus of ${TOTAL} Claude Code session transcripts (${PASSING} pass triage). Codex sessions, when included by backfill, are indexed separately at `.system/state/codex-index.jsonl` and processed through the mixed pending-session synthesizer after this initial Claude-index pass.

## Read this first

1. `${WORK_WIKI}/SCHEMA.md` — the rules. Page shape, frontmatter, naming, discipline.
2. `${WORK_WIKI}/wiki/` — the (currently empty) wiki tree you're filling in.

## Source material

A pre-extracted JSONL index lives at: `${INDEX_FILE}`

Each line is one transcript with these fields:
- `session_id`, `transcript_path`, `cwd`, `git_branch`, `entrypoint`
- `first_ts`, `last_ts`, `duration_sec`
- `user_msg_count`, `assistant_msg_count`
- `first_user_msg` (truncated to 500 chars — your best signal for what the session was about)
- `tools_used` — unique tool names invoked
- `files_touched` — file paths edited/read (top 30)
- `linear_refs` — Linear ticket IDs mentioned
- `passes_triage` — true if this is substantive (≥3 user msgs, ≥120s, not headless)

Supported source counters in page frontmatter are `claude-transcripts`, `codex-sessions`, and `slack-messages`. This prompt's index contributes `claude-transcripts`; the shared synthesizer handles `codex-sessions`.

Read it with `Bash` (jq) — it's a few MB. Filter to `passes_triage:true` unless you specifically need rejected sessions for color.

## Your job

Build the **initial** wiki. The bar is **durability**: future sessions should be able to find their working context here. This is one-shot — be ambitious but disciplined.

### Step 1 — Cluster sessions by project

Group by `cwd` (resolve `worktrees/...` paths back to the repo name). For each distinct project with ≥ 2 substantive sessions, create `wiki/entities/projects/<slug>.md` per SCHEMA.md.

For each project page, derive from the index:
- **Summary**: 1–2 sentences guessing what this project is, based on the first_user_msg samples and files_touched. Mark "(unverified)" where uncertain.
- **Branches**: most common `git_branch` values.
- **Recent activity**: top 5–8 most recent sessions, one-line each (`YYYY-MM-DD — distilled from first_user_msg`).
- **Linear refs**: aggregated from `linear_refs`.
- **Files touched**: top ~20 most frequent files (gives a sense of project shape).
- **Cross-references**: link to relevant concept pages once you've made them in step 2.

For the **3–5 most active projects**, sample 1–2 representative full transcripts using `Read ${TRANSCRIPT_PATH}` or `jq` — pull out durable patterns, named conventions, decisions.

### Step 2 — Identify recurring concepts

Scan `first_user_msg` across the corpus for recurring themes that aren't project-specific:
- Tools/systems that appear repeatedly with consistent purpose (e.g. claude-code hooks, MCP servers, specific CI workflows)
- Patterns or conventions mentioned across multiple projects
- Cross-cutting workflows (PR review, debugging, deploys, testing approaches)

For each concept that appears across ≥ 3 sessions, create `wiki/concepts/<slug>.md`. Cross-link to the project pages where it shows up.

### Step 3 — Identify named technologies

Tools, libraries, frameworks, services that came up substantively across projects. Create `wiki/entities/technologies/<slug>.md` for each major one.

### Step 4 — Build indexes (mechanical, derive directly from the JSONL)

- `wiki/index/by-project.md`: table — `Project | Sessions | Latest activity | Page`. Every project (even single-session ones, with no page link).
- `wiki/index/by-date.md`: month-grouped one-liners pointing to entity pages, derived from the index.
- `wiki/index/glossary.md`: alphabetical short definitions of acronyms/jargon you noticed (e.g. ECA, FAI, UAA — guess from context). Mark uncertain ones "(unverified)".

### Step 5 — Syntheses (skim the corpus; sparse is fine)

- `wiki/syntheses/decisions.md`: durable decisions you found evidence of. If sparse or empty, that's OK.
- `wiki/syntheses/open-questions.md`: questions that recur without clear resolution.
- `wiki/syntheses/recurring-bugs.md`: bug patterns that show up multiple times.

### Step 6 — Top-level navigation

Update `wiki/README.md` (NOT the repo top-level `README.md`) to surface what you built — list of project pages, link to indexes, link to top concepts.

## Discipline (re-read SCHEMA.md if unsure)

- **Distill, don't archive.** Each page should be useful at a glance. ~300 lines max.
- **Frontmatter on every page** — see SCHEMA.md.
- **No invented facts.** The index is your ground truth. Sample transcripts only for depth, not bulk.
- **No per-session entries.** The wiki is entity-shaped, not time-shaped. Time lives only in `index/by-date.md`.
- **Mark uncertainty** with "(unverified)" inline.
- If a project has only 1 substantive session and that session is trivial, **skip it** — leave it in the index but don't make a page.
- **Never modify** files in `${WORK_WIKI}/.system/`.

When you're done, the wiki should have:
- ~10–25 project pages (depending on corpus shape)
- ~5–15 concept pages
- A few technology pages
- Three populated index files
- Sparse-but-real synthesis files
- An updated `wiki/README.md`
