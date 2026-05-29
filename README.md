# LLM Wiki

A persistent, LLM-maintained knowledge base built from agent session transcripts (Claude Code and Codex) plus optional Slack and Granola activity. Modeled on Karpathy's [LLM Wiki](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f) idea: knowledge **compounds** in markdown rather than being rediscovered every session.

## Layers

- **Raw sources** (immutable, outside this repo): Claude Code transcripts in `~/.claude/projects/**/*.jsonl`, Codex rollouts indexed by `~/.codex/state_5.sqlite`, optional Slack history, and optional Granola notes.
- **The wiki** (`wiki/`): LLM-generated markdown organized by entities, concepts, and syntheses. Owned end-to-end by the system.
- **The schema** ([SCHEMA.md](SCHEMA.md)): the rules the LLM follows when ingesting, updating, querying, and linting the wiki.

## Navigation

- [`wiki/entities/projects/`](wiki/entities/projects/) — one page per repo / service / product
- [`wiki/entities/people/`](wiki/entities/people/) — collaborators, reviewers, stakeholders
- [`wiki/entities/technologies/`](wiki/entities/technologies/) — libraries, frameworks, tools
- [`wiki/concepts/`](wiki/concepts/) — recurring patterns, design decisions, durable problems
- [`wiki/syntheses/`](wiki/syntheses/) — cross-cutting analyses (open questions, decisions log, recurring bugs, lint reports)
- [`wiki/index/`](wiki/index/) — auto-derived (by-project, by-date, glossary)

## How it stays alive

Two agent-session ingest paths feed the same pending queue:

- **Claude Code**: a `SessionEnd` hook triages the just-finished transcript and enqueues substantive session tails, using UUID cursors.
- **Codex**: a launchd polling job, installed by default unless disabled, reads `~/.codex/state_5.sqlite` every 15 minutes, finds idle changed rollout JSONL files, and enqueues substantive session tails, using line-count cursors.

Neither ingest path calls an LLM directly. A separate batched **synthesizer** fires when the queue reaches `MAX_PENDING` sessions or the oldest entry crosses `MAX_AGE_HOURS`, reads each queued session's new tail with the configured headless provider, and folds everything wiki-worthy into the relevant pages — entity-shaped, never session-shaped. Claude remains the default provider; `install.sh` asks which provider to use, `--synth-provider codex` switches broadly, and job-specific overrides such as `WORK_WIKI_SLACK_SYNTH_PROVIDER` are still supported. Sessions with an unusually large new tail get their own dedicated synth run instead of being batched. The default install includes a daily launchd plist that fires the synthesizer at 8pm so nothing rots overnight. See [.system/SETUP.md](.system/SETUP.md).

Claude and Codex session ingest both honor `.system/config/session-exclusions.json`, plus the gitignored local override `.system/config/session-exclusions.local.json`. Excluded sessions are filtered before enqueue/backfill synthesis, so the headless provider does not read them.

The synthesizer can also apply structural maintenance autonomously. Today that's **entity renames**: when a transcript contains an explicit textual rename signal (e.g. "rename X → Y"), the agent invokes `.system/scripts/rename-entity.py`, which moves the page, appends the prior slug to its `aliases:` frontmatter (never removed), and rewrites every cross-link in `wiki/**/*.md` — all before folding content updates onto the new path. Renames can also be run by hand from the CLI; see [.system/SETUP.md](.system/SETUP.md#renames-entity-slug-changes).

Process-and-discard ingests can also update the wiki directly and are installed by default unless disabled. Slack prefetches recent messages/threads into a temporary JSONL bundle using `WORK_WIKI_SLACK_TOKEN`, then deletes it after synthesis. Granola polls the Personal API for accessible notes updated since the last successful run, gives the synthesis agent a temporary note/transcript bundle, and then deletes raw meeting content while keeping only cursor and note metadata for change detection.

Supported source counters in page frontmatter are `claude-transcripts`, `codex-sessions`, `slack-messages`, and `granola-notes`.

The installer also makes the wiki discoverable to both interactive agents: it refreshes a marked block in `~/.claude/CLAUDE.md` for Claude Code and in `~/.codex/config.toml` `developer_instructions` for Codex.
