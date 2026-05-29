#!/usr/bin/env bash
# Run an LLM structural review of the wiki and apply high-confidence actions.
# Fully autonomous: the agent acts on findings that meet the per-category
# high-confidence gate in wiki-refactor-review.md (RENAME, RESOLVE, ROT_FIX,
# TRIM), capped at 5 actions per run. Anything that doesn't meet the gate is
# silently dropped and will re-surface next run if still relevant.
#
# No proposals file is produced. SPLIT/DEDUP are auto-applied only when a
# high-confidence refactor-intents.md marker supplies exact boundaries and
# the agent verifies those boundaries against the current pages. The agent
# also deletes the legacy wiki/syntheses/refactor-proposals.md on its first run.
#
# After the agent run, this script commits any wiki/ changes the agent made
# and (if WORK_WIKI_AUTO_PUSH=1) pushes to origin/main.
#
# Manual by default. Can be wired to a daily launchd via
# config/com.work-wiki.refactor-daily.plist.template (see SETUP.md).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_WIKI="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TEMPLATE_FILE="${WORK_WIKI}/.system/prompts/wiki-refactor-review.md"
RUNNER="${WORK_WIKI}/.system/scripts/headless-agent-run.sh"
DATE_STR="$(date '+%Y-%m-%d')"
PROMPT_FILE="/tmp/wiki-refactor-review-prompt.txt"
LOG_FILE="${HOME}/.claude/logs/wiki-refactor-review.log"
AUTO_PUSH="${WORK_WIKI_AUTO_PUSH:-${WORK_TRACKER_AUTO_PUSH:-0}}"

[[ -f "${TEMPLATE_FILE}" ]] || { echo "ERROR: prompt not found at ${TEMPLATE_FILE}" >&2; exit 1; }
mkdir -p "$(dirname "${LOG_FILE}")"

# --- Concurrency guard ---
LOCK_DIR="${WORK_WIKI}/.refactor-review-lock"
if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
  if [[ "${1:-}" == "--force" ]]; then
    rm -rf "${LOCK_DIR}"
    mkdir "${LOCK_DIR}"
  else
    echo "Refactor review already running (lock at ${LOCK_DIR}). Pass --force to override." >&2
    exit 1
  fi
fi
trap 'rm -rf "${LOCK_DIR}"; rm -f "${PROMPT_FILE}"' EXIT

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [refactor-review] $*" | tee -a "${LOG_FILE}"; }

log "=== Start (wiki=${WORK_WIKI}) ==="

export WORK_WIKI DATE_STR TEMPLATE_FILE PROMPT_FILE
python3 <<'PYEOF'
import os
from string import Template
with open(os.environ["TEMPLATE_FILE"]) as f:
    tpl = Template(f.read())
rendered = tpl.safe_substitute(
    WORK_WIKI=os.environ["WORK_WIKI"],
    DATE_STR=os.environ["DATE_STR"],
)
with open(os.environ["PROMPT_FILE"], "w") as f:
    f.write(rendered)
PYEOF

PROVIDER="$("${RUNNER}" --job refactor --print-provider)"
log "Invoking ${PROVIDER}..."
if "${RUNNER}" \
  --job refactor \
  --prompt-file "${PROMPT_FILE}" \
  --allowed-claude-tools "Bash,Read,Write,Glob,Grep" \
  --codex-writable-dir "${WORK_WIKI}" \
  --log-label "wiki-refactor-review" >>"${LOG_FILE}" 2>&1; then
  log "${PROVIDER} exited 0"
else
  EX=$?
  log "WARN: ${PROVIDER} exited ${EX}"
  exit "${EX}"
fi

# --- Commit any wiki/ changes the agent made (auto-applied actions) ---
# Scope is wiki/ only — never touches .system/ or anything else. The agent
# either edits pages directly or makes no changes at all.
CHANGED_FILES="$(git -C "${WORK_WIKI}" status --porcelain -- wiki/ 2>/dev/null | awk '{print $NF}' || true)"
if [[ -z "${CHANGED_FILES}" ]]; then
  log "No actions taken; nothing to commit."
  log "=== Done ==="
  exit 0
fi

APPLIED_COUNT="$(printf '%s\n' "${CHANGED_FILES}" | wc -l | tr -d ' ')"
log "Refactor agent touched ${APPLIED_COUNT} page(s):"
printf '  %s\n' ${CHANGED_FILES} | tee -a "${LOG_FILE}" >/dev/null
COMMIT_MSG="wiki: refactor — applied ${APPLIED_COUNT} action(s) on ${DATE_STR}"

# Share the synthesizer's git lock to avoid racing a concurrent synth commit.
GIT_LOCK="${WORK_WIKI}/.git-commit-lock"
GIT_LOCK_ACQUIRED=false
for _ in $(seq 1 30); do
  if mkdir "${GIT_LOCK}" 2>/dev/null; then
    GIT_LOCK_ACQUIRED=true
    break
  fi
  sleep 1
done

if ! ${GIT_LOCK_ACQUIRED}; then
  log "WARN: could not acquire git lock after 30s; changes left uncommitted in working tree"
  log "=== Done ==="
  exit 0
fi
trap 'rm -rf "${LOCK_DIR}"; rm -f "${PROMPT_FILE}"; rmdir "${GIT_LOCK}" 2>/dev/null || true' EXIT

git -C "${WORK_WIKI}" add -A -- wiki/ 2>/dev/null || true
if git -C "${WORK_WIKI}" commit -m "${COMMIT_MSG}" >>"${LOG_FILE}" 2>&1; then
  log "Committed: ${COMMIT_MSG}"
  if [[ "${AUTO_PUSH}" == "1" || "${AUTO_PUSH}" == "true" ]]; then
    if git -C "${WORK_WIKI}" push origin main >>"${LOG_FILE}" 2>&1; then
      log "Pushed to origin/main"
    else
      log "WARN: push to origin/main failed; commit stays local"
    fi
  else
    log "Skipping push (WORK_WIKI_AUTO_PUSH not set)"
  fi
else
  log "Nothing to commit (working tree clean after agent run)"
fi

log "=== Done ==="
