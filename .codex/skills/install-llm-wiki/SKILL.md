---
name: install-llm-wiki
description: >-
  Install the LLM wiki + worklog onto this machine from Codex. Use when setting
  up the wiki for the first time, onboarding onto a new laptop, or
  re-running the installer after changing options. Checks prerequisites,
  chooses sensible skip-friendly defaults, then runs .system/install.sh.
  Triggers: "install the wiki", "set up llm-wiki", "onboard me onto the wiki",
  "install llm-wiki".
---

# Install LLM Wiki

Guide an engineer through installing this LLM-maintained wiki + worklog. The
real installer is `.system/install.sh`; do not reimplement it. Resolve the repo
root, check prerequisites, choose flags, run the installer, and verify results.

The installer is idempotent and safe to re-run. It prints a plan before it
changes files. It installs context for both Claude Code and Codex.

## What Gets Installed

- Claude Code `SessionEnd` ingest hook and `SessionStart` worklog recall hook.
- Marked context blocks in `~/.claude/CLAUDE.md` and
  `~/.codex/config.toml` top-level `developer_instructions`.
- macOS launchd jobs, depending on selected options: daily synthesizer, Codex
  ingest, Slack daily, Granola daily, refactor-review, and PR-state poller.
- No raw transcripts are stored in the repo; sources are processed and
  discarded or tracked only by cursors.

## Step 1 - Confirm Location And Prerequisites

1. Resolve the repo root:

   ```bash
   git -C "$(pwd)" rev-parse --show-toplevel
   ```

   Confirm `<root>/.system/install.sh` exists. If not, tell the engineer to
   `cd` into their llm-wiki clone and stop.

2. Probe required tools and git identity:

   ```bash
   for t in python3 jq git claude; do command -v "$t" >/dev/null 2>&1 && echo "ok: $t" || echo "MISSING: $t"; done
   git config --get user.name >/dev/null && git config --get user.email >/dev/null && echo "ok: git identity" || echo "MISSING: git identity"
   ```

   Required: `python3`, `jq`, `git`, `claude`, and git `user.name` /
   `user.email`. Stop on missing required prerequisites and give the exact fix
   before continuing.

3. Probe optional integrations:

   ```bash
   command -v codex >/dev/null 2>&1 && test -f "$HOME/.codex/state_5.sqlite" && echo "ok: codex ingest" || echo "skip: codex ingest"
   command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 && echo "ok: pr sync" || echo "skip: pr sync"
   test -n "${WORK_WIKI_SLACK_TOKEN:-}" && echo "ok: slack daily" || echo "skip: slack daily"
   test -n "${WORK_WIKI_GRANOLA_API_KEY:-}" && echo "ok: granola daily" || echo "skip: granola daily"
   ```

   Default optional integrations to enabled only when their probe passes.

## Step 2 - Choose Flags

Use concise questions only when the user has not already specified options.
Otherwise use recommended defaults:

- Synthesis provider: `claude` by default; `codex` only when requested or when
  the engineer explicitly wants Codex CLI to write wiki updates.
- Auto-push: off by default (`--no-auto-push`).
- Optional integrations: enable only probes that passed; pass `--no-enable-*`
  for failed or unwanted integrations.

Flag mapping:

| Choice | Flag |
|---|---|
| provider = codex | `--synth-provider codex` |
| provider = claude | omit provider flag or use `--synth-provider claude` |
| auto-push on | `--auto-push` |
| auto-push off | `--no-auto-push` |
| Codex ingest off | `--no-enable-codex-ingest` |
| PR sync off | `--no-enable-pr-sync` |
| Slack daily off | `--no-enable-slack-daily` |
| Granola daily off | `--no-enable-granola-daily` |

The daily synthesizer and refactor-review default on. Only pass
`--no-enable-daily` or `--no-enable-refactor-daily` if the user explicitly opts
out.

## Step 3 - Run Installer

Run from the repo root. Use `SKIP_AUTH_CHECK=1` when the prerequisite probe has
already covered CLI availability and auth would only slow the run:

```bash
SKIP_AUTH_CHECK=1 bash .system/install.sh --yes --no-auto-push --no-enable-slack-daily --no-enable-granola-daily
```

Adjust flags from Step 2. If a selected integration needs credentials, ensure
the related env var is present in the command environment:

- Slack: `WORK_WIKI_SLACK_TOKEN`
- Granola: `WORK_WIKI_GRANOLA_API_KEY`

The installer writes outside the repo (`~/.claude`, `~/.codex`, and
`~/Library/LaunchAgents`). In Codex, request escalation if the sandbox blocks
the command. If the user declines or the environment cannot run it, print the
exact command for them to run and ask for the output.

## Step 4 - Verify

Check launchd jobs and context installation:

```bash
for j in daily slack-daily granola-daily refactor-daily codex-ingest pr-sync; do
  launchctl print "gui/$(id -u)/com.work-wiki.$j" >/dev/null 2>&1 && echo "loaded: $j" || echo "not loaded: $j"
done
readlink ~/.claude/hooks/wiki-session-end.sh
grep -n "work-wiki" ~/.codex/config.toml
```

Report the chosen provider, loaded jobs, skipped integrations, and exact fixes
for skipped-but-desired integrations (`WORK_WIKI_SLACK_TOKEN`,
`WORK_WIKI_GRANOLA_API_KEY`, `gh auth login`, or install/run `codex`).

Mention first-time backfill as an optional follow-up:

```bash
bash .system/scripts/backfill.sh
bash .system/scripts/backfill.sh --include-codex
```

Uninstall path: `.system/uninstall.sh`.
