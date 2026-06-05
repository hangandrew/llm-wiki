---
name: install-llm-wiki
description: >-
  Install the LLM wiki + worklog onto this machine. Walks a new engineer through
  prerequisites and configuration choices (with skip-friendly defaults), detects
  which integrations their machine can support, then runs .system/install.sh.
  Use when setting up the wiki for the first time, onboarding onto a new laptop,
  or re-running the installer after changing options. Triggers: "install the
  wiki", "set up llm-wiki", "onboard me onto the wiki".
---

# Install LLM Wiki

You are guiding an engineer through installing this LLM-maintained wiki + worklog
onto their machine. The real installer is `.system/install.sh` — your job is to
**check prerequisites, gather choices with sensible defaults, then drive that
script**. Do not reimplement install logic; assemble flags and run the installer.

The installer is idempotent and safe to re-run. It prints a full plan and asks
before executing.

## What gets installed

- A `SessionEnd` hook (Claude Code) + a `SessionStart` recall hook.
- Marked context blocks in `~/.claude/CLAUDE.md` and `~/.codex/config.toml` so
  agents know the wiki exists.
- launchd jobs (macOS): daily synthesizer (8pm), Codex ingest (every 15 min),
  Slack daily, Granola daily, refactor-review (8:30pm), PR-state poller (10 min).
- No raw transcripts are stored; sources are processed and discarded.

## Step 1 — Confirm location & prerequisites

1. Resolve the repo root and confirm `.system/install.sh` exists:
   `git -C "$(pwd)" rev-parse --show-toplevel` then check `<root>/.system/install.sh`.
   If not found, tell the engineer to `cd` into their llm-wiki clone and stop.
2. Run a quick prerequisite probe and report what's present/missing. Required:
   `python3`, `jq`, `git`, and the `claude` CLI. Also check git global identity
   (`git config --get user.name` / `user.email`) — the installer needs it for
   commits.
   ```
   for t in python3 jq git claude; do command -v "$t" >/dev/null 2>&1 && echo "ok: $t" || echo "MISSING: $t"; done
   git config --get user.name >/dev/null && git config --get user.email >/dev/null && echo "ok: git identity" || echo "MISSING: git identity (set user.name/user.email, or pass WORK_WIKI_GIT_NAME/WORK_WIKI_GIT_EMAIL)"
   ```
3. Detect optional-integration capabilities so you can default smartly in Step 2.
   Treat each as "available" only if its probe passes:
   - **Codex ingest** — `command -v codex` AND `~/.codex/state_5.sqlite` exists.
   - **PR-state sync** — `gh auth status` succeeds (`gh` installed and logged in).
   - **Slack daily** — env var `WORK_WIKI_SLACK_TOKEN` is set.
   - **Granola daily** — env var `WORK_WIKI_GRANOLA_API_KEY` is set.
   If a required prerequisite (python3/jq/git/claude/identity) is missing, stop and
   give the engineer the exact fix (e.g. `brew install jq`, `gh auth login`) before
   continuing.

## Step 2 — Gather choices (skip-friendly defaults)

Use **AskUserQuestion** to collect the configuration. Default every answer so the
engineer can accept the recommended setup without thinking, and default
credential-dependent integrations to **skip** when their probe failed in Step 1.

Ask these (combine into one AskUserQuestion call with multiple questions):

1. **Synthesis provider** — which headless LLM writes the wiki.
   - `claude` *(Recommended)* — uses the local Claude Code subscription auth.
   - `codex` — uses the Codex CLI (only sensible if `codex` is installed).
2. **Auto-push** — push wiki commits to the remote automatically?
   - `Skip` *(Recommended default)* — keep commits local; push by hand.
   - `Enable` — set `WORK_WIKI_AUTO_PUSH=1` (only if they have push rights).
3. **Optional integrations** (multiSelect) — pre-select only the ones whose probe
   passed in Step 1; leave the rest unchecked (skipped):
   - Codex session ingest
   - PR-state sync (needs authenticated `gh`)
   - Slack daily ingest (needs `WORK_WIKI_SLACK_TOKEN`)
   - Granola daily ingest (needs `WORK_WIKI_GRANOLA_API_KEY`)

The **core** install (hooks + daily synthesizer + refactor-review) always happens;
those are not optional questions.

If the engineer wants the no-questions path, you may skip AskUserQuestion and use
the recommended defaults directly (claude provider, no auto-push, integrations
enabled only where probes passed).

## Step 3 — Assemble flags and run the installer

Build the `install.sh` invocation from the answers. Always pass `--yes` (you've
already gathered the choices) and `SKIP_AUTH_CHECK=1` (the prereq probe covered
auth; this avoids a slow extra check). Map each answer to a flag:

| Choice | Flag |
|---|---|
| provider = codex | `--synth-provider codex` (omit for claude) |
| auto-push = enable | `--auto-push` (else `--no-auto-push`) |
| Codex ingest off | `--no-enable-codex-ingest` |
| PR-sync off | `--no-enable-pr-sync` |
| Slack daily off | `--no-enable-slack-daily` |
| Granola daily off | `--no-enable-granola-daily` |

The daily synthesizer and refactor-review default ON; only pass
`--no-enable-daily` / `--no-enable-refactor-daily` if the engineer explicitly
opted out.

Run from the repo root, e.g.:
```
cd "<repo-root>" && SKIP_AUTH_CHECK=1 bash .system/install.sh --yes --no-enable-slack-daily --no-enable-granola-daily
```
For integrations that need credentials and the engineer DID opt in, prefix the
relevant env var on the same command (e.g. `WORK_WIKI_SLACK_TOKEN=xoxb-…`).

If the environment blocks you from executing the installer, **print the exact
command** for the engineer to run themselves and ask them to paste the output back.

## Step 4 — Verify and report

After install, confirm it took:
```
for j in daily slack-daily granola-daily refactor-daily codex-ingest pr-sync; do
  launchctl print "gui/$(id -u)/com.work-wiki.$j" >/dev/null 2>&1 && echo "loaded: $j" || echo "not loaded: $j"
done
readlink ~/.claude/hooks/wiki-session-end.sh
```
Then summarize: which jobs are loaded, the provider chosen, and any integration
that was **skipped because a credential/tool was missing** — tell them exactly
what to set (`WORK_WIKI_SLACK_TOKEN`, `WORK_WIKI_GRANOLA_API_KEY`, `gh auth login`,
install `codex`) and that re-running this skill will enable it.

Mention the optional **backfill** step for populating the wiki from existing
history: `.system/scripts/backfill.sh` (point them at `.system/SETUP.md` for
details). To reverse everything later: `.system/uninstall.sh`.
