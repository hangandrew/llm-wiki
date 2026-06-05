# Work Wiki — Setup Guide

A persistent, LLM-maintained wiki of work context. Karpathy-style ([gist](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f)): raw sources are folded into a synthesized knowledge layer, and `SCHEMA.md` is the contract the maintainer LLM follows. Today's sources: Claude Code transcripts, Codex rollout sessions, and daily Slack or Granola activity when the related credentials are available.

**Agent-session pipeline.** A `SessionEnd` hook fires after each Claude Code session, and the default install includes a Codex ingest job that polls `~/.codex/state_5.sqlite` every 15 minutes for idle changed rollout files. Both paths triage substantive sessions and **enqueue** them into the same pending queue. A separate batched **synthesizer** fires when the queue is large enough or has aged out, folding all queued sessions into the wiki in a single run. The default install also includes a daily launchd plist that fires the synthesizer at 8pm so nothing rots overnight.

**Slack pipeline.** The default install includes a separate daily launchd plist that runs `slack-ingest.sh` at 8pm. It prefetches the user's recent messages + threads into a temporary JSONL bundle, then the configured headless provider triages aggressively and folds durable signal into the same wiki tree. Process-and-discard: no raw retention, only a single ISO-8601 timestamp cursor at `.system/state/slack-ingest-cursor.txt`. Wiki changes are committed after a successful agent run and pushed when `WORK_WIKI_AUTO_PUSH=1` is set in the environment or `~/.claude/settings.json`.

**Granola pipeline.** The default install includes a separate daily launchd plist that runs `granola-ingest.sh` at 8pm. It polls Granola's Personal API for accessible notes updated since the last successful run, fetches changed note details with transcripts into a temporary `/tmp` JSONL bundle, lets the configured headless provider synthesize durable wiki changes, then deletes the raw bundle. Persisted state is limited to `.system/state/granola-ingest-cursor.json` and per-note metadata under `.system/state/granola-notes/` for unchanged-note skipping.

## Requirements

- Claude Code CLI (`claude`) — installed and authenticated
- Codex CLI (`codex`) — required only when Codex ingest is enabled or any synthesizer provider is set to `codex`
- `sqlite3` — required only when Codex ingest is enabled
- Granola Personal API key — required for the default Granola daily job to succeed; pass `--no-enable-granola-daily` to skip Granola ingest
- Slack token in `WORK_WIKI_SLACK_TOKEN` — required for the default Slack daily job to succeed; pass `--no-enable-slack-daily` to skip Slack ingest
- `jq` — `brew install jq` on macOS, `apt install jq` on Linux
- `python3` — standard on macOS; `apt install python3` on Linux
- `git` — configured with your identity (`git config --global user.name` / `user.email`)

## Install

```bash
git clone <repo-url> ~/work-wiki
bash ~/work-wiki/.system/install.sh
```

The installer runs a **preflight** before touching anything: checks `python3`, `jq`, `git`, and `claude` are on PATH; checks `sqlite3`/`codex` only when needed; verifies `git config --global user.name`/`user.email` are set; and fires one trivial `claude -p` prompt to confirm the CLI is authenticated. If any check fails it exits with a copy-pasteable fix. For offline reinstalls or CI runs where the auth check is wasteful, set `SKIP_AUTH_CHECK=1`:

```bash
SKIP_AUTH_CHECK=1 bash ~/work-wiki/.system/install.sh
```

Idempotent — safe to re-run. It also migrates the legacy `work-tracker` install in place: removes the old `knowledge-session-end.sh` symlink, rewrites the `SessionEnd` entry in `~/.claude/settings.json`, replaces the `<!-- work-tracker -->` block in `~/.claude/CLAUDE.md` with `<!-- work-wiki -->`, and migrates `WORK_TRACKER_AUTO_PUSH` → `WORK_WIKI_AUTO_PUSH`.

The installer also injects the same Work Wiki pointer into Codex by updating the top-level `developer_instructions` string in `~/.codex/config.toml`. Existing Codex developer instructions are preserved; the installer only refreshes the marked `<!-- work-wiki -->` block.

## Headless Provider Selection

All wiki-writing LLM jobs go through `.system/scripts/headless-agent-run.sh`. `install.sh` asks which provider to use and writes the selected value to both `~/.claude/settings.json` and the launchd plists it renders. Claude is the default for compatibility:

```bash
WORK_WIKI_SYNTH_PROVIDER=claude   # default
WORK_WIKI_SYNTH_PROVIDER=codex    # broad switch to Codex CLI
```

For unattended installs, pass the choice explicitly:

```bash
bash ~/work-wiki/.system/install.sh --yes --synth-provider claude
bash ~/work-wiki/.system/install.sh --yes --synth-provider codex
```

Use job-specific overrides for staged rollout:

```bash
WORK_WIKI_SESSION_SYNTH_PROVIDER=codex
WORK_WIKI_BACKFILL_SYNTH_PROVIDER=codex
WORK_WIKI_SLACK_SYNTH_PROVIDER=codex
WORK_WIKI_GRANOLA_SYNTH_PROVIDER=codex
WORK_WIKI_LINT_SYNTH_PROVIDER=codex
WORK_WIKI_REFACTOR_SYNTH_PROVIDER=codex
WORK_WIKI_COMPRESS_SYNTH_PROVIDER=codex
```

Resolution order is job-specific env var, then `WORK_WIKI_SYNTH_PROVIDER`, then `claude`. Codex runs as `codex -a never exec -C "$WORK_WIKI" -s workspace-write -`, so install/authenticate the Codex CLI only when one of those values is `codex` or Codex ingest is enabled.

For unattended runs:
```bash
bash ~/work-wiki/.system/install.sh --yes                                            # install all integrations; auto-push skipped
bash ~/work-wiki/.system/install.sh --yes --auto-push                                # install all integrations and enable auto-push
bash ~/work-wiki/.system/install.sh --yes --synth-provider codex                     # install with Codex as the wiki-writing provider
bash ~/work-wiki/.system/install.sh --yes --no-enable-codex-ingest                   # install all except Codex ingest
bash ~/work-wiki/.system/install.sh --yes --no-enable-slack-daily --no-enable-granola-daily  # skip external app ingests
bash ~/work-wiki/.system/install.sh --yes --no-auto-push --no-enable-daily --no-enable-slack-daily --no-enable-granola-daily --no-enable-refactor-daily --no-enable-codex-ingest
```

By default, the installer renders every launchd plist and runs `launchctl load -w` for you (idempotent — re-runs unload first to refresh). Use the matching `--no-enable-*` flag to skip an integration. If the load fails for any reason, it prints the manual command and continues; you can also run it yourself later:
```bash
launchctl load -w ~/Library/LaunchAgents/com.work-wiki.daily.plist
launchctl load -w ~/Library/LaunchAgents/com.work-wiki.slack-daily.plist
launchctl load -w ~/Library/LaunchAgents/com.work-wiki.granola-daily.plist
launchctl load -w ~/Library/LaunchAgents/com.work-wiki.refactor-daily.plist
launchctl load -w ~/Library/LaunchAgents/com.work-wiki.codex-ingest.plist
```

### Credentials: the secrets file

The Slack and Granola ingest jobs need credentials that launchd jobs **cannot**
inherit from your interactive shell. The installer stores them once in a single
`0600` env file — `~/.config/work-wiki/secrets.env` (override the path with
`WORK_WIKI_SECRETS_FILE`) — and `slack-ingest.sh` / `granola-ingest.sh` source it
at runtime. This is decoupled from the launchd plists (so a re-run, which
re-renders the plists, never wipes your tokens) and from `settings.json` (so the
secrets aren't loaded into every interactive Claude session).

```
# ~/.config/work-wiki/secrets.env   (chmod 600)
WORK_WIKI_SLACK_TOKEN=xoxp-…
WORK_WIKI_GRANOLA_API_KEY=grn_…
```

The installer writes this file when you pass the tokens — via `--slack-token` /
`--granola-key`, via the `WORK_WIKI_SLACK_TOKEN` / `WORK_WIKI_GRANOLA_API_KEY`
environment variables, or via the interactive prompt. Each token is **validated
against its API before being stored** (Slack `auth.test`, a 1-item Granola notes
fetch): a token the API definitively rejects is reported and *not* stored, so a
typo'd or revoked key fails at install time instead of silently at 8pm. A
transient failure (network down, rate-limit) stores the token with a warning
rather than blocking. Set `WORK_WIKI_SKIP_TOKEN_CHECK=1` to skip validation
entirely (offline installs). A re-run with no token supplied **preserves**
whatever is already stored; it never clobbers a key with a blank. A real
environment variable always wins over the file, so manual runs still work:

```bash
WORK_WIKI_GRANOLA_API_KEY=... bash ~/work-wiki/.system/scripts/granola-ingest.sh --force
```

**Slack token** (`WORK_WIKI_SLACK_TOKEN`): must call Slack Web API `auth.test`,
`search.messages`, and `conversations.replies`. `search.messages` requires a
**user** token (`xoxp-…`), not a bot token, with `search:read` + the relevant
`*:history` scopes for the channels you want ingested.

**Granola key** (`WORK_WIKI_GRANOLA_API_KEY`): a Granola Personal API key.

**Rotating a key:** edit the one file (or re-run the installer with the new
token) — no plist changes needed. The next scheduled run picks it up.

## First-time backfill

Run **once** after install to seed the wiki from your existing transcripts:

```bash
bash ~/work-wiki/.system/scripts/backfill.sh
bash ~/work-wiki/.system/scripts/backfill.sh --include-codex
```

Two passes:
1. `backfill-extract.py` walks `~/.claude/projects/**/*.jsonl` and writes a metadata index to `.system/state/backfill-index.jsonl`. Cheap, jq/python only. With `--include-codex`, `codex-extract.py` also indexes `~/.codex/state_5.sqlite` threads to `.system/state/codex-index.jsonl` and enqueues historical Codex sessions through the mixed-source queue.
2. `backfill-synthesize.sh` invokes the configured headless provider to read the Claude index and build the initial `wiki/` (entity pages, concept pages, indexes, syntheses). With `--include-codex`, the shared synthesizer then processes the Codex queue instead of using a separate wiki-writing path.

The backfill is idempotent — running it again refines rather than duplicates.

## Customization

| Variable | Default | Description |
|----------|---------|-------------|
| `WORK_WIKI_DIR` | `~/work-wiki` | Path to the wiki repo |
| `WORK_WIKI_GIT_NAME` | global `git config user.name` | Name used for git commits |
| `WORK_WIKI_GIT_EMAIL` | global `git config user.email` | Email for git commits |
| `WORK_WIKI_AUTO_PUSH` | unset (off) | `1`/`true` to push origin/main after each commit |
| `WORK_WIKI_SYNTH_PROVIDER` | `claude` | Global headless provider: `claude` or `codex` |
| `WORK_WIKI_SESSION_SYNTH_PROVIDER` | unset | Override provider for queued session synthesis |
| `WORK_WIKI_BACKFILL_SYNTH_PROVIDER` | unset | Override provider for backfill synthesis |
| `WORK_WIKI_SLACK_SYNTH_PROVIDER` | unset | Override provider for Slack ingest synthesis |
| `WORK_WIKI_GRANOLA_SYNTH_PROVIDER` | unset | Override provider for Granola ingest synthesis |
| `WORK_WIKI_LINT_SYNTH_PROVIDER` | unset | Override provider for semantic lint |
| `WORK_WIKI_REFACTOR_SYNTH_PROVIDER` | unset | Override provider for refactor review |
| `WORK_WIKI_COMPRESS_SYNTH_PROVIDER` | unset | Override provider for recent-activity compression |
| `WORK_WIKI_MAX_PENDING` | `5` | Fire synthesizer when this many sessions are queued |
| `WORK_WIKI_MAX_AGE_HOURS` | `6` | Fire synthesizer when oldest queued session is this old |
| `WORK_WIKI_LARGE_TAIL_USER_MSGS` | `50` | Sessions whose new tail exceeds this user-msg count get a dedicated synth run |
| `WORK_WIKI_LARGE_TAIL_BYTES` | `500000` | Sessions whose new tail exceeds this byte size get a dedicated synth run |
| `WORK_WIKI_CODEX_IDLE_MINUTES` | `10` | Codex threads must be this idle before polling ingest enqueues them |
| `WORK_WIKI_SECRETS_FILE` | `~/.config/work-wiki/secrets.env` | Path to the 0600 credentials file the ingest jobs source |
| `WORK_WIKI_SLACK_TOKEN` | unset | Slack user token (`xoxp-…`) for `slack-ingest.sh` — store in the secrets file, **not** settings.json |
| `WORK_WIKI_GRANOLA_API_KEY` | unset | Granola Personal API key for `granola-ingest.sh` — store in the secrets file, **not** settings.json |
| `WORK_WIKI_GRANOLA_LOOKBACK_HOURS` | `24` | First-run/default Granola updated-note window |
| `WORK_WIKI_GRANOLA_OVERLAP_MINUTES` | `15` | Overlap applied to the last successful Granola cursor |
| `WORK_WIKI_GRANOLA_PAGE_SIZE` | `30` | Granola list page size, clamped to API max 30 |

Set these in `~/.claude/settings.json` under an `env` block — Claude Code injects them into every hook subprocess regardless of how it was launched (terminal, desktop app, IDE):

```json
{
  "env": {
    "WORK_WIKI_DIR": "/Users/jane/my-wiki",
    "WORK_WIKI_AUTO_PUSH": "1"
  }
}
```

Legacy `WORK_TRACKER_*` names are still accepted as fallbacks for one release.

**Triage thresholds** (top of `wiki-session-end.sh`):
```bash
MIN_USER_MESSAGES=3       # filters out quick queries
MIN_DURATION_SECONDS=120  # filters out abandoned sessions
```

**Synthesizer triggers** (configurable via env vars in the table above):

| Trigger | Default | Effect |
|---------|---------|--------|
| Queue depth | 5 sessions | Hook fires synthesizer in background |
| Oldest pending age | 6 hours | Hook fires synthesizer in background |
| Daily synthesizer plist | 8pm (default) | Fires `wiki-synthesizer.sh` regardless of queue state |
| Daily Slack-ingest plist | 8pm (default) | Fires `slack-ingest.sh` (independent pipeline, separate lock) |
| Daily Granola-ingest plist | 8pm (default) | Fires `granola-ingest.sh` (independent pipeline, separate lock) |

A pending session whose new tail (records since the last successful synth for that session) exceeds `LARGE_TAIL_USER_MSGS` or `LARGE_TAIL_BYTES` gets its own dedicated headless provider run inside the synthesizer; everything below threshold is folded into one batched run. A 200-message conversation that was synthesized then resumed with 1 new message classifies as small (1 msg in the new tail) — only genuinely-large new content escalates.

## Session exclusions

Claude and Codex session ingest share one exclusion config:

```text
.system/config/session-exclusions.json        # committed shared rules
.system/config/session-exclusions.local.json  # gitignored machine-local rules
```

Excluded sessions are filtered before enqueueing and before Claude historical backfill writes its metadata index. If either JSON file is malformed, ingest fails closed for that run rather than silently reading sessions you intended to exclude.

Example:

```json
{
  "version": 1,
  "rules": [
    {
      "id": "private-or-personal",
      "enabled": true,
      "sources": ["claude", "codex"],
      "reason": "Do not ingest personal sessions into work wiki",
      "match": {
        "cwd_prefixes": [
          "/Users/andrewjhang/personal",
          "/Users/andrewjhang/Downloads"
        ],
        "repo_names": ["private-notes"],
        "git_branch_globs": ["personal/*", "scratch/private-*"],
        "title_regexes": ["(?i)personal", "(?i)private"],
        "first_user_message_regexes": ["(?i)do not ingest", "(?i)private conversation"]
      }
    },
    {
      "id": "specific-sessions",
      "enabled": true,
      "sources": ["claude", "codex"],
      "reason": "Manual one-off exclusions",
      "match": {
        "session_ids": ["claude-session-uuid-here", "codex-thread-id-here"],
        "transcript_path_globs": [
          "*/.claude/projects/*/sensitive-session.jsonl",
          "*/.codex/rollouts/*/sensitive-thread.jsonl"
        ]
      }
    }
  ]
}
```

Rule semantics:

- A rule applies only when `enabled` is true or omitted, the session source is in `sources` or `sources` is omitted, and any matcher under `match` hits.
- Exact matchers: `session_ids`, `repo_names`, `agent_roles`, `agent_paths`, `agent_nicknames`, `thread_sources`.
- Prefix matcher: `cwd_prefixes`.
- Glob matchers: `cwd_globs`, `git_branch_globs`, `transcript_path_globs`.
- Regex matchers: `title_regexes`, `first_user_message_regexes`.

## Renames (entity slug changes)

When a project, concept, technology, or person page is renamed (e.g. `error-classification-agent` → `resolve-agent`), use:

```bash
python3 ~/work-wiki/.system/scripts/rename-entity.py --type project --old <current-slug> --new <new-slug>
python3 ~/work-wiki/.system/scripts/rename-entity.py --type project --old <current-slug> --new <new-slug> --dry-run  # preview
```

What it does (applies by default):
- Moves `wiki/<dir>/<old>.md` → `wiki/<dir>/<new>.md`.
- Rewrites frontmatter — sets `slug`, bumps `updated:` to today, **appends** to `aliases:` (never replaces; old slugs are kept forever).
- Rewrites every markdown link in `wiki/**/*.md` that targets the old `.md` file. URLs (`://`) are skipped.
- Reports — but does not rewrite — bare prose mentions of the old slug; auto-prose-rewrite is intentionally out of scope (e.g. "(formerly X)" and quoted history are legitimate).

The synthesizer can also call this script autonomously when a session contains an explicit textual rename signal — see `wiki-synthesize-pending.md` and `wiki-update.md` for the trigger rules. The conservative bias is: rename only on explicit textual cues, never on inferred refactors or file moves in target repos.

## Linting

Cheap deterministic checks:

```bash
python3 ~/work-wiki/.system/scripts/check-wiki.py
```

Runs local-only validation for shell/Python syntax, required wiki frontmatter, slug/filename drift, broken relative markdown links, oversized Recent-activity bullets, and forbidden `[[wikilinks]]`. It exits non-zero on any finding and does not call an LLM or write files.

Semantic LLM audit:

```bash
bash ~/work-wiki/.system/scripts/lint.sh
```

Runs the configured headless provider to audit the wiki for orphans, broken links, contradictions, missing index entries, frontmatter issues, duplicates, length violations, and knowledge gaps. Output: `wiki/syntheses/lint-<date>.md`. Manual only — not wired to any schedule.

## Recent-activity bullet compression

SCHEMA caps each Recent-activity bullet at 200 characters (one line, no sub-bullets). Drift over time is inevitable. This script detects and compresses offenders:

```bash
python3 ~/work-wiki/.system/scripts/compress-recent-activity.py                     # report-only (default)
python3 ~/work-wiki/.system/scripts/compress-recent-activity.py --json              # machine-readable
python3 ~/work-wiki/.system/scripts/compress-recent-activity.py --compress          # rewrite all in place
python3 ~/work-wiki/.system/scripts/compress-recent-activity.py --compress --limit 5  # worst 5 only
python3 ~/work-wiki/.system/scripts/compress-recent-activity.py wiki/entities/projects/foo.md  # scope to a page
```

Default mode is detect-only — prints over-budget bullets sorted by char count, no edits. With `--compress`, each over-budget bullet is rewritten via the configured headless provider to <=200 chars, preserving the date prefix and every markdown link verbatim (links are pointers, not paraphrasable prose). Rewrites that fail validation (still over budget, lost the date prefix) are skipped with a warning. The page's `updated:` frontmatter is bumped only when at least one bullet on it actually rewrites.

Manual only — not wired to the synthesizer. Run after a synth pass produced bloated entries, or as a periodic sweep.

## Synthesis-rot detection

Synthesis pages (decisions log, open questions, recurring bugs) summarize state across the wiki. They go stale when entity pages they reference move on without the synthesis being revisited. This script flags those cases via frontmatter date math — no LLM call:

```bash
python3 ~/work-wiki/.system/scripts/detect-synthesis-rot.py                       # default threshold: 7 days
python3 ~/work-wiki/.system/scripts/detect-synthesis-rot.py --threshold-days 3
python3 ~/work-wiki/.system/scripts/detect-synthesis-rot.py --json
```

A synthesis is "rotting" when at least one linked entity page has `updated:` newer by >= threshold days. Output lists each rotting synthesis, its `updated:` date, and the freshest linked entities (top 5). Lint reports (`lint-*.md`) are skipped — they are frozen snapshots, not maintained pages.

Detection only: the user (or a downstream agent) reads the synthesis + the newer entity pages and decides what to update. There's no auto-write path because date math alone can't tell whether a referenced question was actually resolved by a later session — that judgment requires reading content.

## Post-synth detection hook

After every synth pass, `wiki-synthesizer.sh` invokes `.system/scripts/post-synth-detect.sh` and logs any findings to `wiki-synthesizer.log`. Two passes run:

1. **Bullet verbosity** — scoped to pages the synth modified in this run (`git diff --name-only -- wiki/`). Catches drift introduced by the synth itself.
2. **Synthesis rot** — wiki-wide, since rot signals what the synth *failed* to touch.

Both detectors are pure-Python and exit-safe; failures never block the commit. Output appears in the log as `WARN:` lines after the synth runs and before the commit. Example:

```
[2026-05-13 21:00:12] [synth] WARN: 3 over-budget Recent-activity bullet(s) on synth-touched pages (cap: 200 chars)
[2026-05-13 21:00:12] [synth]   wiki/entities/projects/foo.md:42  385c  47w
[2026-05-13 21:00:12] [synth] WARN: 1 synthesis page(s) rotting (>= 7d behind linked entities)
[2026-05-13 21:00:12] [synth]   wiki/syntheses/decisions.md  updated 2026-05-01  rot=12d  newer_links=4/9
```

**Auto-compress on touched pages** runs automatically before the detector via `.system/scripts/auto-compress-touched.sh`. After every successful synth, it scopes via `git diff --name-only` to the pages the synth modified and invokes `compress-recent-activity.py --compress` on them, so rewrites fold into the same commit as the synth's content. Failures are silent — the original bullet stays, and the detector below logs the residual.

The detector then runs as a final pass. WARN lines now reflect only what the auto-compress could not fix (LLM rewrites that didn't shrink the bullet, or rot signals the compressor can't address). This is the **measurement loop** — over time, persistent WARNs identify where the LLM compression keeps failing, which can drive prompt-tuning rather than pipeline changes.

## LLM structural review (autonomous)

The cheap mechanical detectors above surface symptoms (bloated bullets, stale syntheses). They cannot make structural judgment calls — when a question in `open-questions.md` was actually resolved by a later session, when a rename has landed in prose but cross-links still point at the old slug, when a synthesis item references an entity page that has moved on. This script runs the configured headless provider and **applies high-confidence findings directly** with no other artifact:

```bash
bash ~/work-wiki/.system/scripts/refactor-review.sh           # respects the lock
bash ~/work-wiki/.system/scripts/refactor-review.sh --force   # bypass a stale lock
```

Runs the configured headless provider with `wiki-refactor-review.md`. The agent runs the cheap detectors, reads flagged pages, and **auto-applies** every finding that meets the per-category high-confidence gate. Categories:

- **RENAME** — explicit past-tense or in-progress textual signal; new slug doesn't yet exist. Runs `rename-entity.py`.
- **RESOLVE** — synthesis item resolved by quotable verbatim prose on a specific entity page. Edits the synthesis file to close/remove the item, citing the resolving page.
- **ROT_FIX** — synthesis item whose linked entity is ≥7d newer with prose that directly updates/supersedes it. Edits the item in place, citing the new prose.
- **TRIM** — Recent-activity section > 12 entries with ≥3 entries older than the current month. Drops oldest, keeps newest 10.
- **SPLIT, DEDUP** — only auto-applied when an explicit intent marker exists in `wiki/syntheses/refactor-intents.md` (written by the synthesizer from a live session — see below). The marker must name exact `## <header>` boundaries and target slugs; if not, the marker persists for hand-resolution. Hard cap: 1 SPLIT + 1 DEDUP per run.

Hard caps: 5 actions per run; never two actions to the same file; no chained auto-applies. Anything not meeting the high-confidence gate is dropped and will re-surface next run if still relevant — there is no proposals file, no pending-review queue, no checkbox flow.

### Intent markers (SPLIT, DEDUP)

The mechanical detectors can find candidates for renames, resolves, and recent-activity overflow on their own. They **cannot** find safe SPLIT or DEDUP boundaries — those require knowing where the content cleavage goes, which only the original conversation has. So the synthesizer captures intent during a session and the daily refactor-review pass acts on it.

The synth prompts (`wiki-synthesize-pending.md`, `wiki-update.md`) detect these textual signals in transcripts:

- **SPLIT:** "split X into Y and Z", "pull Y out of X as its own page", "X is becoming an umbrella for ..."
- **DEDUP:** "X and Y restate the same thing — X is canonical", "Y should just link to X", "consolidate Y into X"

When detected, the synth appends a structured entry to `wiki/syntheses/refactor-intents.md` with: recorded date, source quote, source/target page paths, exact `## <header>` sections to move or replace, and a confidence assessment. Refactor-review consumes entries whose confidence is `high` and whose boundaries verify against the current source page; consumed entries are deleted from the file. Entries that fail the gate stay put — markers that survive ~30 daily runs signal the intent was insufficient and need a human resolution.

No inference: the synth records SPLIT/DEDUP only on explicit textual signals, never on inferred page size or content overlap.

After the agent exits, the shell script detects which `wiki/` pages were modified (`git status --porcelain`), commits them with `wiki: refactor — applied N action(s) on <date>`, and pushes when `WORK_WIKI_AUTO_PUSH` is set. The synthesizer's git lock is shared, so a concurrent synth run cannot race the commit.

Wired by default by `install.sh`; pass `--no-enable-refactor-daily` to skip it. Schedule: daily at 8:30pm. Logs to `~/.claude/logs/wiki-refactor-review.log` and `wiki-refactor-review-daily.log`. Uninstall via the matching `--keep-refactor-daily` flag (omit to remove). Legacy `--enable-refactor-weekly` / `--keep-refactor-weekly` flags are still accepted; install.sh and uninstall.sh both clean up the predecessor `com.work-wiki.refactor-weekly.plist` if it's still loaded.

**Reverting an auto-apply:** `git -C ~/work-wiki log --grep='wiki: refactor'` to find the commit, then `git revert <sha>`. The commit diff is the record of what was applied.

## Slack ingest (manual run)

```bash
bash ~/work-wiki/.system/scripts/slack-ingest.sh           # respects the lock
bash ~/work-wiki/.system/scripts/slack-ingest.sh --force   # bypass a stale lock
```

Prefetches recent Slack messages/threads into a temporary JSONL bundle, then invokes the configured headless provider with `wiki-update-slack.md`. Reads the cursor at `.system/state/slack-ingest-cursor.txt` to determine the fetch window; on agent exit 0, commits any `wiki/` changes as `wiki: slack ingest on <date>` and pushes when `WORK_WIKI_AUTO_PUSH=1` is set in the environment or `~/.claude/settings.json`. The cursor advances to the run-start timestamp only after the agent and commit step succeed; on agent or commit failure, the cursor is **not** advanced, so the next successful run catches up. First run defaults to 24h ago; cursors older than 30 days are clamped to 30d ago.

Slack prefetch uses `WORK_WIKI_SLACK_TOKEN` (fallbacks: `SLACK_USER_TOKEN`, `SLACK_BOT_TOKEN`) and deletes the raw bundle on exit. Only the cursor is retained.

## Keeping the tooling up to date

This repo (`llm-wiki`) is the source of truth for the `.system/` installer and
automation code. If you cloned it and filled in your own `wiki/` + `worklog/`,
you can pull later tooling updates **without touching your private content**:

```bash
# one-time: point at the public template
git remote add upstream git@github.com:hangandrew/llm-wiki.git

# whenever you want the latest tooling:
bash .system/scripts/sync-system.sh             # pull + commit .system/ updates
bash .system/scripts/sync-system.sh --dry-run   # preview the .system/ changes only
bash .system/scripts/sync-system.sh --no-commit # apply + stage, you commit
```

`sync-system.sh` only ever modifies files under `.system/` — your `wiki/` and
`worklog/` are never touched, and the gitignored `.system/state/` (cursors,
queue) is left alone. It pulls from `upstream/main` by default (override with
`WORK_WIKI_UPSTREAM_REMOTE` / `WORK_WIKI_UPSTREAM_BRANCH`), aborts if any change
outside `.system/` would be staged, and never pushes anything upstream — data
flows into your instance only. Re-run `install.sh` after a sync if a launchd
plist template or hook changed.

## Uninstall

```bash
bash ~/work-wiki/.system/uninstall.sh
```

The script prints the planned actions and asks for confirmation before doing anything. It removes the SessionEnd hook symlink, strips the wiki entry + env vars from `~/.claude/settings.json`, deletes the `<!-- work-wiki -->` block from `~/.claude/CLAUDE.md` and `~/.codex/config.toml`, and (if installed) `launchctl unload`s and removes the synthesizer-daily, Slack-daily, Codex-ingest, and refactor-daily plists.

It never touches the wiki repo, its git history, or `.system/state/` — those are your content (cursors, queue state, etc. are preserved across re-installs). Delete them by hand if you want a full wipe.

Flags:
```bash
bash ~/work-wiki/.system/uninstall.sh --yes                     # skip confirmation
bash ~/work-wiki/.system/uninstall.sh --keep-daily              # leave the synthesizer launchd plist alone
bash ~/work-wiki/.system/uninstall.sh --keep-slack-daily        # leave the Slack-ingest launchd plist alone
bash ~/work-wiki/.system/uninstall.sh --keep-codex-ingest       # leave the Codex-ingest launchd plist alone
bash ~/work-wiki/.system/uninstall.sh --keep-settings-env       # leave WORK_WIKI_* env vars in settings.json
```

## Logs

```bash
tail -f ~/.claude/logs/wiki-session-end.log         # triage + enqueue decisions
tail -f ~/.claude/logs/wiki-synthesizer.log         # batched synthesizer (hook-fired and manual)
tail -f ~/.claude/logs/wiki-synthesizer-daily.log   # daily launchd-fired synthesizer (if installed)
tail -f ~/.claude/logs/slack-ingest.log             # Slack-ingest runs (manual and launchd-fired)
tail -f ~/.claude/logs/slack-ingest-daily.log       # launchd stdout/stderr for the Slack-daily plist
tail -f ~/.claude/logs/wiki-backfill.log            # initial backfill output
tail -f ~/.claude/logs/wiki-codex-ingest.log        # Codex polling ingest (manual and launchd-fired)
```

To run the synthesizer manually (e.g. after tweaking thresholds):
```bash
bash ~/work-wiki/.system/hooks/wiki-synthesizer.sh           # respects the lock
bash ~/work-wiki/.system/hooks/wiki-synthesizer.sh --force   # bypass a stale lock
```

## Repo layout

```
work-wiki/
├── README.md             # entry point (human-facing)
├── SCHEMA.md             # rules the maintainer LLM follows
├── wiki/
│   ├── entities/{projects,people,technologies}/
│   ├── concepts/
│   ├── syntheses/        # cross-cutting analyses, lint reports
│   └── index/            # by-project, by-date, glossary (auto-derivable)
└── .system/
    ├── hooks/            # wiki-session-end.sh, wiki-synthesizer.sh
    ├── prompts/          # wiki-update.md, wiki-synthesize-pending.md, wiki-initial-build.md, wiki-lint.md, wiki-update-slack.md, wiki-refactor-review.md
    ├── scripts/          # backfill.sh, backfill-extract.{py,sh}, codex-extract.py, codex-ingest.sh, auto-compress-touched.sh, backfill-synthesize.sh, compress-recent-activity.py, detect-synthesis-rot.py, lint.sh, post-synth-detect.sh, refactor-review.sh, rename-entity.py, slack-ingest.sh
    ├── config/           # settings-patch.json, com.work-wiki.daily.plist.template, com.work-wiki.slack-daily.plist.template, com.work-wiki.codex-ingest.plist.template, com.work-wiki.refactor-daily.plist.template
    ├── state/
    │   ├── sessions/                   # uuid resume cursors (per session, transcript pipeline)
    │   ├── codex-sessions/             # line-count resume cursors (per Codex thread)
    │   ├── pending/                    # queued sessions awaiting synthesis
    │   └── slack-ingest-cursor.txt     # ISO-8601 last-successful-run timestamp (Slack pipeline)
    ├── install.sh
    ├── uninstall.sh
    └── SETUP.md          # this file
```

## How it works

1. **SessionEnd hook** (`wiki-session-end.sh`) fires once per Claude Code session end (`/exit`, `/clear`, logout). Does not fire on ungraceful terminations (kill, terminal closed, crash).
2. The triage script checks:
   - Transcript `entrypoint != sdk-cli` (skips headless `claude -p` runs spawned by the synthesizer itself, preventing recursive loops)
   - ≥ 3 user messages (filters quick queries)
   - ≥ 2 minutes elapsed (filters abandoned sessions)
3. If all gates pass, it writes a source-aware JSON entry to `.system/state/pending/<session_id>-<ts>.json` describing the session (`source`, transcript path, project, branch, `cursor_type`, current cursor) and exits. Session close is never delayed.
4. The hook then checks two trigger conditions:
   - Queue depth ≥ `WORK_WIKI_MAX_PENDING` (default 5)
   - Oldest pending file mtime ≥ `WORK_WIKI_MAX_AGE_HOURS` (default 6h)
   If either fires, the hook launches `wiki-synthesizer.sh` in the background; otherwise it exits and waits for the next trigger or the daily floor.
5. **The synthesizer** (`wiki-synthesizer.sh`) acquires a process lock, dedupes pending entries by `source + session_id` (keeps the latest enqueued entry per source/session), and classifies each surviving entry by its **new tail**. Claude uses UUID cursors at `.system/state/sessions/<id>.uuid`; Codex uses line-count cursors at `.system/state/codex-sessions/<id>.line`. Sessions whose new tail exceeds `WORK_WIKI_LARGE_TAIL_USER_MSGS` or `WORK_WIKI_LARGE_TAIL_BYTES` are "large" and get their own dedicated headless provider run; everything else is folded into a single batched run.
6. The batched run uses `.system/prompts/wiki-synthesize-pending.md`; the per-session large runs use `.system/prompts/wiki-update.md`. Both go through `.system/scripts/headless-agent-run.sh`.
7. The configured headless provider reads `SCHEMA.md`, reads each transcript's new tail, and folds any genuinely durable info into the relevant `wiki/entities/`, `wiki/concepts/`, `wiki/syntheses/`, or `wiki/index/` pages. It writes nothing if nothing wiki-worthy surfaced. If a transcript contains an **explicit textual rename signal** for an existing entity, the agent invokes `.system/scripts/rename-entity.py` *before* folding content updates, so subsequent edits land on the post-rename path.
8. On success, per-session cursors advance and the corresponding pending files are deleted. On failure, pending files stay in place and are retried next run.
9. A single git commit covers all successful runs in the synthesizer pass. Push happens only when `WORK_WIKI_AUTO_PUSH` is enabled.
10. **Optional daily floor**: if installed, the launchd plist at `~/Library/LaunchAgents/com.work-wiki.daily.plist` fires the synthesizer every day at 8pm. It's safe to leave loaded — it acquires the same lock as the hook-fired runs and exits cleanly when there's nothing pending.
11. **Optional Slack pipeline**: if installed, `~/Library/LaunchAgents/com.work-wiki.slack-daily.plist` fires `slack-ingest.sh` daily at 8pm (independent lock, independent log). The script reads the cursor at `.system/state/slack-ingest-cursor.txt`, prefetches messages/threads into `/tmp`, renders `.system/prompts/wiki-update-slack.md`, and invokes the configured headless provider. The agent reads the local bundle, triages aggressively, updates wiki pages, and exits. The script deletes the bundle, commits `wiki/` changes, pushes when `WORK_WIKI_AUTO_PUSH` is enabled, and advances the cursor only after the agent and commit step succeed; failed runs leave the cursor in place so the next run catches up.
12. **Optional Codex pipeline**: if installed, `~/Library/LaunchAgents/com.work-wiki.codex-ingest.plist` fires `codex-ingest.sh` every 15 minutes. The script reads `~/.codex/state_5.sqlite`, skips archived/subagent/background/active threads, enqueues changed rollout files after `WORK_WIKI_CODEX_IDLE_MINUTES`, and lets the shared synthesizer batch Codex and Claude sessions together.

## Adding new ingest sources

The wiki is source-agnostic. Two patterns are supported (see SCHEMA.md → "Source contract for ingest"):

**Structured pattern** (used by transcripts, suitable for Notion-style archives):

1. Write an `*-extract.{py,sh}` that walks the source and emits `.system/state/<source>-index.jsonl` per the contract in `SCHEMA.md` (one JSON object per raw record).
2. Either: feed it through the existing synthesize prompt (rename the source field), or write a per-source synthesize prompt that targets the same `wiki/` tree.
3. Schedule via `/schedule` or a cron (or trigger manually).

**Process-and-discard pattern** (used by Slack ingest — see `.system/scripts/slack-ingest.sh` for the working example):

1. Write a daily script that captures `RUN_START_TS`, reads a single-line cursor at `.system/state/<source>-ingest-cursor.txt` (defaulting to a sensible window on first run), and renders a per-source prompt at `.system/prompts/wiki-update-<source>.md` via `Template.safe_substitute`.
2. Prefetch raw content into a temporary bundle, render a prompt that points at the bundle, then invoke `.system/scripts/headless-agent-run.sh`.
3. On agent exit 0, commit any `wiki/` changes, optionally push when `WORK_WIKI_AUTO_PUSH=1`, then atomically write `RUN_START_TS` to the cursor file. On agent or commit failure, leave the cursor untouched so the next run catches up.
4. Add a launchd plist template under `.system/config/` and wire it through `install.sh` (flag, status helper, render block, `launchctl_reload` call) and `uninstall.sh` (`--keep-<source>-daily` flag, status helper, unload+remove block).

The wiki structure doesn't change in either case — it's still entity/concept-shaped, with a `sources.<source>: <count>` line added to the frontmatter of any page that source contributes to. Only the ingest layer expands.
