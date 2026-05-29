# Wiki

This directory holds the LLM-maintained knowledge base. It starts empty — the system
populates it from your own agent session transcripts. See [SCHEMA.md](../SCHEMA.md) for the
rules the synthesizer follows and [../README.md](../README.md) for the broader system design.

## Layout

- [`entities/projects/`](entities/projects/) — one page per repo / service / product
- [`entities/people/`](entities/people/) — collaborators, reviewers, stakeholders
- [`entities/technologies/`](entities/technologies/) — libraries, frameworks, tools
- [`concepts/`](concepts/) — recurring patterns, design decisions, durable problems
- [`syntheses/`](syntheses/) — cross-cutting analyses (open questions, decisions log, recurring bugs)
- [`index/`](index/) — auto-derived (by-project, by-date, glossary)

## Getting started

Run the installer in [`.system/`](../.system/) (see [`.system/SETUP.md`](../.system/SETUP.md)).
Once installed, your wiki fills in automatically as agent sessions complete.
