# Wiki Schema

This file is the contract between the human (curator) and the LLM (maintainer). The LLM reads this file before every wiki update.

## Purpose

The wiki is a **persistent knowledge base** distilled from agent session transcripts and selected work messages. Goals:
- Knowledge compounds across sessions instead of being rediscovered.
- Pages are organized around **stable entities and concepts**, not around the time something was discussed.
- The human curates raw sources; the LLM does the maintenance work.

## What goes in the wiki

Anything **durable** that's worth knowing in a future session:
- **Entities**: projects (repos, services), people (collaborators, reviewers), technologies (libraries, frameworks, tools)
- **Concepts**: design decisions, recurring patterns, durable problems, named conventions
- **Syntheses**: open questions across the system, decisions log, recurring bugs, lint reports

What does **not** go in:
- Per-session diaries, time-shaped logs (the timeline lives only as a thin pointer in `index/by-date.md`)
- Transient state (in-progress branches, today's todo list)
- Anything trivially derivable from `git log`, `git blame`, or the source files in target repos
- Verbatim quotes from transcripts longer than necessary — distill, don't archive

## Directory layout

```
wiki/
  entities/
    projects/<slug>.md       # one page per repo or service
    people/<slug>.md         # one page per named collaborator
    technologies/<slug>.md   # one page per library/framework/tool that came up substantively
  concepts/<slug>.md         # patterns, design decisions, recurring problems
  syntheses/                 # cross-cutting analyses; safe to regenerate
    open-questions.md
    decisions.md
    recurring-bugs.md
    lint-<YYYY-MM-DD>.md     # output of lint runs
  index/                     # mechanical, derivable from the rest of the wiki
    by-project.md            # table: project | sessions | latest activity
    by-date.md               # date-ordered thin pointers to entity pages
    glossary.md              # short definitions, alphabetical
```

## Slug conventions

- Lowercase kebab-case. Examples: `fai-automation-backend`, `error-classification-agent`, `claude-code`, `linear-api`.
- Slug is also the filename: `wiki/entities/projects/fai-automation-backend.md`.
- Slug must be unique across its directory. If a slug collides, disambiguate with a parent prefix (e.g. `andrewhang-work-wiki` vs `acme-work-wiki`).

## Page shape

Every page begins with frontmatter:
```
---
type: project | person | technology | concept | synthesis | index
slug: <slug>
aliases: [<prior-slug>, ...]    # optional; present iff the page has been renamed
created: <YYYY-MM-DD>
updated: <YYYY-MM-DD>
sources:
  - claude-transcripts: <count>
  - codex-sessions: <count>
  - slack-messages: <count>     # optional, only when Slack ingest contributed
  - granola-notes: <count>      # optional, only when Granola ingest contributed
---
```

`aliases:` records every prior slug this page has been known by. It exists so that (1) cross-link rewrites during a rename are auditable, (2) future ingest passes can recognize the old name in transcripts and route content to the renamed page, and (3) grep-by-old-name still finds the entity. Inline (`aliases: [a, b]`) and block (`aliases:\n  - a\n  - b`) forms are both accepted. Renames are performed by `.system/scripts/rename-entity.py`, which applies by default and appends to `aliases:` rather than replacing it. Old slugs in `aliases:` are never removed.

`<count>` may be either an integer (when the page is built from a directly enumerable cluster of sessions or messages — e.g. project pages where every session in the cwd is counted) or a `~N` approximation (e.g. `~10`, `~30`) when the count is inferred from text-search across many sources (typical for concept and technology pages). Approximations are honest about uncertainty; don't promote them to integers if the underlying count is fuzzy.

The `sources:` list is open-ended: include only the source types that actually contributed to the page. Today the supported source types are `claude-transcripts` (Claude Code session transcripts), `codex-sessions` (Codex rollout JSONL files indexed by `~/.codex/state_5.sqlite`), `slack-messages` (the daily Slack ingest, see `.system/scripts/slack-ingest.sh`), `granola-notes` (the daily Granola ingest, see `.system/scripts/granola-ingest.sh`), and `lint-pass` (generated lint artifacts only). Future sources (Notion, Linear, etc.) follow the same pattern and should be added to the deterministic checker when introduced.

Then a `# Title` and free-form markdown. Suggested sections (use only what applies):
- **Summary** — 1–3 sentences. Stable across updates.
- **Key facts** — short bullets.
- **Recent activity** — most recent first, capped at ~10 entries. Each entry is **one line, ≤200 characters**, format `YYYY-MM-DD — one-line takeaway with [optional inline links](../path.md).` Hard rules:
  - No sub-bullets, no nested lists, no embedded newlines, no multi-sentence summaries inside an entry.
  - **Link, don't paraphrase.** If substance lives in an exec plan, PR, RCA doc, Notion page, or commit, link to it — do not mirror its body into the entry.
  - If a change is too rich for one line, it belongs in a concept page, a `decisions.md` entry, or the linked external source — not in Recent activity.
  - An entry should answer "what changed and where does the detail live," not "what happened in the session."
- **Open questions** — uncertainties worth re-checking. Each item in `wiki/syntheses/open-questions.md` must include a lifecycle line immediately after the heading: `Status: open`, `Status: resolved <YYYY-MM-DD>`, or `Status: stale <YYYY-MM-DD>`.
- **Decisions / Patterns** — durable choices.
- **Cross-references** — standard markdown links to related pages, e.g. `[github-app-tokens](../technologies/github-app-tokens.md)`. Use relative paths from the current page.
- **References** — Linear IDs, PR URLs, external docs.

## Update rules (incremental)

When ingesting new material:
1. Read this SCHEMA.md first.
2. Identify the entities and concepts the new material touches.
3. For each, **prefer updating an existing page** over creating a new one. Search by slug, by aliases, by content before creating.
4. Edit in place. Refresh the `updated:` frontmatter date.
5. Move stale items out of `Recent activity` once the list exceeds ~10 entries — most recent first.
6. **Do not duplicate**: if a fact lives on an entity page, don't repeat it on a concept page; link instead.
7. **Don't write a session log.** If an exchange surfaced nothing durable, write nothing.
8. Update `index/by-project.md` whenever `entities/projects/` changes; `index/by-date.md` for any wiki-touching session.
9. Keep `index/by-date.md` thin: no totals sections, no paragraph summaries, and every bullet must be one line and ≤200 characters.

## Discipline

- Pages are **distillations, not archives**. Length cap: ~300 lines per page; if longer, split into focused sub-pages.
- **Stable summary, evolving body.** The opening summary changes only when scope genuinely changes.
- **No invented facts.** If something isn't supported by the raw sources, don't write it. Mark uncertain claims with "(unverified)".
- **Cross-link liberally.** Use standard markdown links — `[name](relative/path.md)`. When prose names an entity or concept that has its own page, link to it inline on first mention in that section. Every entity page should link to at least one concept page and vice versa where relevant.
- **Lint regularly** ([.system/scripts/lint.sh](.system/scripts/lint.sh)): orphans, contradictions, broken links, missing index entries.
- **Run deterministic checks** (`.system/scripts/check-wiki.py`) after structural changes. It catches syntax errors, frontmatter drift, unsupported source names, broken links, oversized activity/index lines, missing project index entries, page-length cap breaches, stale `updated:` dates on dirty files, and `[[wikilink]]` regressions.

## Source contract for ingest

Sources may be either **structured** (the JSONL pattern below) or **streaming / process-and-discard** (the Slack pattern).

**Structured sources** produce a JSONL extract at `.system/state/<source>-index.jsonl`. Each line should include at minimum:
- `source` — string identifier (`claude`, `codex`, `notion`)
- `id` — stable identifier from the source
- `timestamp` — ISO-8601
- `cwd` / `channel` / `space` — origin context
- `summary` or `first_msg` — short text to seed clustering
- Source-specific extras

The synthesize prompt for structured sources is source-agnostic: it reads the JSONL, clusters by entity, and updates wiki pages following the rules above.

**Process-and-discard sources** (e.g. Slack via `.system/scripts/slack-ingest.sh`, Granola via `.system/scripts/granola-ingest.sh`) do not retain raw message/note bodies in the repo. The daily script either invokes a headless Claude agent with restricted read tools (Slack) or writes a temporary `/tmp` JSONL bundle for the agent to read (Granola), triages, updates wiki pages, and discards the raw fetch. Persisted state is limited to cursors and source metadata required to skip unchanged content, e.g. Granola note `updated_at`, content hash, title, owner, URL, and last processed timestamp. Source-specific prompts (`.system/prompts/wiki-update-<source>.md`) carry the fetch + triage rules.
