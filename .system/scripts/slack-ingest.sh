#!/usr/bin/env bash
# Daily Slack ingest. Prefetches the user's recent Slack messages + threads
# into a temporary JSONL bundle, then spawns the configured headless agent to
# triage them and fold durable signal into wiki pages.
#
# Process-and-discard: no pending queue, no raw retention. The only persisted
# state is a single-line ISO-8601 cursor at .system/state/slack-ingest-cursor.txt
# that marks the last successful run-start time, so each run fetches exactly
# the window since the last successful run.
#
# Triggered by:
#   - launchd daily plist (com.work-wiki.slack-daily) at 8pm if installed
#   - manual invocation: bash slack-ingest.sh [--force]
#
# After a successful agent run, commits any wiki/ changes and pushes when
# WORK_WIKI_AUTO_PUSH=1/true. The Slack cursor advances only after this
# persistence step succeeds, so failed commits retry the same Slack window.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_WIKI="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TEMPLATE_FILE="${WORK_WIKI}/.system/prompts/wiki-update-slack.md"
PREFETCHER="${WORK_WIKI}/.system/scripts/slack-prefetch.py"
RUNNER="${WORK_WIKI}/.system/scripts/headless-agent-run.sh"
CURSOR_FILE="${WORK_WIKI}/.system/state/slack-ingest-cursor.txt"
LOCK_DIR="${WORK_WIKI}/.system/state/slack-ingest.lock"
STATE_DIR="${WORK_WIKI}/.system/state"
LOG_DIR="${HOME}/.claude/logs"
LOG_FILE="${LOG_DIR}/slack-ingest.log"
SETTINGS_FILE="${HOME}/.claude/settings.json"
AUTO_PUSH="${WORK_WIKI_AUTO_PUSH:-${WORK_TRACKER_AUTO_PUSH:-}}"
if [[ -z "${AUTO_PUSH}" && -f "${SETTINGS_FILE}" ]] && command -v jq >/dev/null 2>&1; then
  AUTO_PUSH="$(jq -r '.env.WORK_WIKI_AUTO_PUSH // .env.WORK_TRACKER_AUTO_PUSH // ""' "${SETTINGS_FILE}" 2>/dev/null || true)"
fi
AUTO_PUSH="${AUTO_PUSH:-0}"

mkdir -p "${STATE_DIR}" "${LOG_DIR}"

ts() { date '+%Y-%m-%dT%H:%M:%S'; }
log() { echo "[$(ts)] [slack-ingest] $*" >> "${LOG_FILE}"; }

FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    -h|--help)
      cat <<EOF
Usage: slack-ingest.sh [--force]
  --force   Bypass the lock file (use if a stale lock is wedged)
EOF
      exit 0
      ;;
  esac
done

[[ -f "${TEMPLATE_FILE}" ]] || { echo "ERROR: prompt template not found at ${TEMPLATE_FILE}" >&2; log "ABORT: missing template ${TEMPLATE_FILE}"; exit 1; }
[[ -f "${PREFETCHER}" ]] || { echo "ERROR: Slack prefetcher not found at ${PREFETCHER}" >&2; log "ABORT: missing prefetcher ${PREFETCHER}"; exit 1; }
[[ -n "${WORK_WIKI_SLACK_TOKEN:-${SLACK_USER_TOKEN:-${SLACK_BOT_TOKEN:-}}}" ]] || { echo "ERROR: WORK_WIKI_SLACK_TOKEN is required" >&2; log "ABORT: missing WORK_WIKI_SLACK_TOKEN"; exit 2; }

# --- Lock ---
if [[ "$FORCE" -eq 1 ]]; then
  rmdir "$LOCK_DIR" 2>/dev/null || true
fi
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  log "SKIP: another slack-ingest is running (lock: $LOCK_DIR)"
  exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM

log "=== Starting slack-ingest run ==="

# --- Cursor: read or default to 24h ago; clamp absurdly old (>30d) to 30d ago ---
NOW_EPOCH="$(date -u '+%s')"
THIRTY_DAYS_AGO_EPOCH=$(( NOW_EPOCH - 30 * 86400 ))

# macOS BSD date for both -v and -r forms.
iso_from_epoch() { date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ'; }
default_since_iso() { date -u -v-24H '+%Y-%m-%dT%H:%M:%SZ'; }

if [[ -f "${CURSOR_FILE}" ]]; then
  SINCE_TS="$(cat "${CURSOR_FILE}" | tr -d '[:space:]')"
  if [[ -z "${SINCE_TS}" ]]; then
    SINCE_TS="$(default_since_iso)"
    log "Cursor file empty; using default 24h-ago floor (${SINCE_TS})"
  else
    # Parse the cursor to epoch for clamp comparison. Tolerate parse failure.
    CURSOR_EPOCH=0
    if command -v gdate >/dev/null 2>&1; then
      CURSOR_EPOCH="$(gdate -u -d "${SINCE_TS}" '+%s' 2>/dev/null || echo 0)"
    fi
    if [[ "${CURSOR_EPOCH}" -eq 0 ]]; then
      # macOS BSD date parse fallback (expects -j -f format).
      CURSOR_EPOCH="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "${SINCE_TS}" '+%s' 2>/dev/null || echo 0)"
    fi
    if [[ "${CURSOR_EPOCH}" -eq 0 ]]; then
      log "WARN: could not parse cursor '${SINCE_TS}'; falling back to 24h-ago floor"
      SINCE_TS="$(default_since_iso)"
    elif [[ "${CURSOR_EPOCH}" -lt "${THIRTY_DAYS_AGO_EPOCH}" ]]; then
      OLD_SINCE="${SINCE_TS}"
      SINCE_TS="$(iso_from_epoch "${THIRTY_DAYS_AGO_EPOCH}")"
      log "WARN: cursor ${OLD_SINCE} is older than 30d; clamping to ${SINCE_TS}"
    else
      log "Cursor read: ${SINCE_TS}"
    fi
  fi
else
  SINCE_TS="$(default_since_iso)"
  log "First run (no cursor file); using default 24h-ago floor (${SINCE_TS})"
fi

RUN_START_TS="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
TODAY_DATE="$(date '+%Y-%m-%d')"
log "Run start: ${RUN_START_TS}; window: ${SINCE_TS} → now"

BUNDLE_FILE="$(mktemp /tmp/slack-ingest-bundle.XXXXXX.jsonl)"
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true; rm -f "${BUNDLE_FILE}"' EXIT INT TERM
PREFETCH_LOG="${LOG_DIR}/slack-prefetch.log"
PREFETCH_JSON="$(python3 "${PREFETCHER}" \
  extract \
  --since "${SINCE_TS}" \
  --run-start "${RUN_START_TS}" \
  --bundle "${BUNDLE_FILE}" \
  2>>"${PREFETCH_LOG}")"
log "prefetch ${PREFETCH_JSON}"
MESSAGE_COUNT="$(PREFETCH_JSON="${PREFETCH_JSON}" python3 <<'PYEOF'
import json
import os
try:
    print(int(json.loads(os.environ["PREFETCH_JSON"]).get("messages", 0)))
except Exception:
    print(0)
PYEOF
)"

if [[ "${MESSAGE_COUNT}" -eq 0 ]]; then
  TMP_CURSOR="${CURSOR_FILE}.tmp"
  echo "${RUN_START_TS}" > "${TMP_CURSOR}"
  mv "${TMP_CURSOR}" "${CURSOR_FILE}"
  log "No Slack messages in window; cursor advanced → ${RUN_START_TS}"
  rm -f "${BUNDLE_FILE}"
  log "=== Done (exit=0) ==="
  exit 0
fi

# --- Snapshot existing entity slugs for prompt ---
existing_projects() {
  find "${WORK_WIKI}/wiki/entities/projects" -mindepth 1 -maxdepth 1 -name '*.md' 2>/dev/null \
    | xargs -I {} basename {} .md | sort | sed 's/^/- /'
}
existing_concepts() {
  find "${WORK_WIKI}/wiki/concepts" -mindepth 1 -maxdepth 1 -name '*.md' 2>/dev/null \
    | xargs -I {} basename {} .md | sort | sed 's/^/- /'
}
EXISTING_PROJECTS="$(existing_projects)"; [[ -z "${EXISTING_PROJECTS}" ]] && EXISTING_PROJECTS="(none yet)"
EXISTING_CONCEPTS="$(existing_concepts)"; [[ -z "${EXISTING_CONCEPTS}" ]] && EXISTING_CONCEPTS="(none yet)"

# --- Render prompt ---
PROMPT_FILE="$(mktemp /tmp/slack-ingest-prompt.XXXXXX)"
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true; rm -f "${PROMPT_FILE}" "${BUNDLE_FILE}"' EXIT INT TERM

export TEMPLATE_FILE PROMPT_FILE WORK_WIKI SINCE_TS RUN_START_TS TODAY_DATE \
       EXISTING_PROJECTS EXISTING_CONCEPTS BUNDLE_FILE MESSAGE_COUNT

python3 <<'PYEOF'
import os
from string import Template
with open(os.environ["TEMPLATE_FILE"]) as f:
    tpl = Template(f.read())
rendered = tpl.safe_substitute(
    WORK_WIKI=os.environ.get("WORK_WIKI", ""),
    SINCE_TS=os.environ.get("SINCE_TS", ""),
    RUN_START_TS=os.environ.get("RUN_START_TS", ""),
    TODAY_DATE=os.environ.get("TODAY_DATE", ""),
    BUNDLE_FILE=os.environ.get("BUNDLE_FILE", ""),
    MESSAGE_COUNT=os.environ.get("MESSAGE_COUNT", ""),
    EXISTING_PROJECTS=os.environ.get("EXISTING_PROJECTS", ""),
    EXISTING_CONCEPTS=os.environ.get("EXISTING_CONCEPTS", ""),
)
with open(os.environ["PROMPT_FILE"], "w") as f:
    f.write(rendered)
PYEOF

# --- Invoke headless agent ---
PROVIDER="$("${RUNNER}" --job slack --print-provider)"
log "Invoking ${PROVIDER} (slack-ingest) for ${MESSAGE_COUNT} message(s)..."
EX=0
"${RUNNER}" \
  --job slack \
  --prompt-file "${PROMPT_FILE}" \
  --allowed-claude-tools "Read,Write,Edit,Glob,Grep,Bash" \
  --codex-readable-dir "$(dirname "${BUNDLE_FILE}")" \
  --codex-writable-dir "${WORK_WIKI}" \
  --log-label "slack-ingest" \
  >> /dev/null 2>&1 || EX=$?
log "${PROVIDER} exited: ${EX}"

# --- Commit any wiki/ changes before advancing the Slack cursor ---
PERSIST_OK=1
if [[ "${EX}" -eq 0 ]]; then
  CHANGED_FILES="$(git -C "${WORK_WIKI}" status --porcelain -- wiki/ 2>/dev/null || true)"
  if [[ -n "${CHANGED_FILES}" ]]; then
    GIT_LOCK="${WORK_WIKI}/.git-commit-lock"
    GIT_LOCK_ACQUIRED=false
    for _ in $(seq 1 30); do
      if mkdir "${GIT_LOCK}" 2>/dev/null; then
        GIT_LOCK_ACQUIRED=true
        break
      fi
      sleep 1
    done

    if ${GIT_LOCK_ACQUIRED}; then
      trap 'rmdir "$LOCK_DIR" 2>/dev/null || true; rmdir "${GIT_LOCK}" 2>/dev/null || true; rm -f "${PROMPT_FILE}" "${BUNDLE_FILE}"' EXIT INT TERM
      git -C "${WORK_WIKI}" add -A -- wiki/ 2>/dev/null || true
      COMMIT_MSG="wiki: slack ingest on ${TODAY_DATE}"
      if git -C "${WORK_WIKI}" commit -m "${COMMIT_MSG}" >> "${LOG_FILE}" 2>&1; then
        log "Committed: ${COMMIT_MSG}"
        if [[ "${AUTO_PUSH}" == "1" || "${AUTO_PUSH}" == "true" ]]; then
          if git -C "${WORK_WIKI}" push origin main >> "${LOG_FILE}" 2>&1; then
            log "Pushed to origin/main"
          else
            log "WARN: push to origin/main failed; commit stays local"
          fi
        else
          log "Skipping push (WORK_WIKI_AUTO_PUSH not set)"
        fi
      else
        log "WARN: git commit failed; cursor NOT advanced"
        PERSIST_OK=0
      fi
      rmdir "${GIT_LOCK}" 2>/dev/null || true
      trap 'rmdir "$LOCK_DIR" 2>/dev/null || true; rm -f "${PROMPT_FILE}" "${BUNDLE_FILE}"' EXIT INT TERM
    else
      log "WARN: could not acquire git lock after 30s; cursor NOT advanced"
      PERSIST_OK=0
    fi
  else
    log "No wiki changes to commit"
  fi
fi

# --- Cursor advance (only after successful agent + persistence) ---
if [[ "${EX}" -eq 0 && "${PERSIST_OK}" -eq 1 ]]; then
  TMP_CURSOR="${CURSOR_FILE}.tmp"
  echo "${RUN_START_TS}" > "${TMP_CURSOR}"
  mv "${TMP_CURSOR}" "${CURSOR_FILE}"
  log "Cursor advanced → ${RUN_START_TS}"
elif [[ "${EX}" -ne 0 ]]; then
  log "WARN: agent exited non-zero; cursor NOT advanced (will retry same window next run)"
else
  log "WARN: persistence failed; cursor NOT advanced (will retry same window next run)"
fi

log "=== Done (exit=${EX}) ==="
exit 0
