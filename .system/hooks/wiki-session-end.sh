#!/usr/bin/env bash
# Triage + enqueue hook: fires on SessionEnd (graceful terminations only —
# /exit, /clear, logout). Decides whether the session is substantive enough
# to enqueue, writes a pending entry, and fires the batched synthesizer only
# when the queue is large enough or has aged out. MUST always exit 0 — never
# blocks session close.

set -euo pipefail

# --- Triage thresholds ---
MIN_USER_MESSAGES=3
MIN_DURATION_SECONDS=120

# --- Synthesizer-trigger thresholds ---
MAX_PENDING="${WORK_WIKI_MAX_PENDING:-5}"
MAX_AGE_HOURS="${WORK_WIKI_MAX_AGE_HOURS:-6}"

# --- Paths ---
WORK_WIKI="${WORK_WIKI_DIR:-${WORK_TRACKER_DIR:-${HOME}/work-wiki}}"
SYNTHESIZER="${WORK_WIKI}/.system/hooks/wiki-synthesizer.sh"
PENDING_DIR="${WORK_WIKI}/.system/state/pending"
LOG_DIR="${HOME}/.claude/logs"
LOG_FILE="${LOG_DIR}/wiki-session-end.log"

mkdir -p "${LOG_DIR}" "${PENDING_DIR}"

ts() { date '+%Y-%m-%dT%H:%M:%S'; }
log() { echo "[$(ts)] [end-hook] $*" >> "${LOG_FILE}"; }

# Portable mtime in epoch seconds (macOS BSD stat / Linux GNU stat).
file_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
}

# --- Read hook payload ---
INPUT="$(cat)"
SESSION_ID="$(echo "${INPUT}" | jq -r '.session_id // empty' 2>/dev/null || true)"
TRANSCRIPT_PATH="$(echo "${INPUT}" | jq -r '.transcript_path // empty' 2>/dev/null || true)"

if [[ -z "${SESSION_ID}" || -z "${TRANSCRIPT_PATH}" ]]; then
  log "SKIP: Missing session_id or transcript_path"
  exit 0
fi

if [[ ! -f "${TRANSCRIPT_PATH}" ]]; then
  log "SKIP: Transcript not found: ${TRANSCRIPT_PATH}"
  exit 0
fi

log "Evaluating session ${SESSION_ID}"

# --- Triage 0: Skip headless invocations to prevent recursion ---
# The synthesizer can spawn headless providers. Claude headless runs use
# entrypoint=sdk-cli, which itself fires
# SessionEnd when it finishes. Without this gate, every synthesizer run would
# recursively trigger another run.
ENTRYPOINT="$(grep '"entrypoint"' "${TRANSCRIPT_PATH}" 2>/dev/null | head -1 | jq -r '.entrypoint // empty' 2>/dev/null || true)"
if [[ "${ENTRYPOINT}" == "sdk-cli" ]]; then
  log "SKIP: headless sdk-cli session (would cause recursive synthesizer run)"
  exit 0
fi

# --- Triage 1: User message count ---
USER_MSG_COUNT="$(jq -s '
  map(select(
    .type == "user"
    and (.isMeta // false | not)
    and (.isSidechain // false | not)
    and ((.message.content | type) != "string"
         or ((.message.content | startswith("<local-command-stdout>") | not)
             and (.message.content | startswith("<local-command-caveat>") | not)
             and (.message.content | test("^<command-name>/(exit|clear|logout|compact)") | not)))
  )) | length
' "${TRANSCRIPT_PATH}" 2>/dev/null || echo 0)"
if [[ "${USER_MSG_COUNT}" -lt "${MIN_USER_MESSAGES}" ]]; then
  log "SKIP: Only ${USER_MSG_COUNT} user messages (min ${MIN_USER_MESSAGES})"
  exit 0
fi

# --- Triage 2: Session duration ---
DURATION_SEC="$(jq -s -r '
  [.[] | select(.timestamp) | .timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601] as $ts
  | if ($ts | length) >= 2
    then (($ts | max) - ($ts | min))
    else -1 end
' "${TRANSCRIPT_PATH}" 2>/dev/null || echo -1)"

if [[ "${DURATION_SEC}" -lt 0 ]]; then
  log "SKIP: Could not determine duration from transcript"
  exit 0
fi

if [[ "${DURATION_SEC}" -lt "${MIN_DURATION_SECONDS}" ]]; then
  log "SKIP: Duration ${DURATION_SEC}s < ${MIN_DURATION_SECONDS}s"
  exit 0
fi
log "PASS: ${USER_MSG_COUNT} msgs, ${DURATION_SEC}s"

# --- Extract session context ---
SESSION_CWD="$(grep '"role":"user"' "${TRANSCRIPT_PATH}" | head -1 | jq -r '.cwd // empty' 2>/dev/null || true)"
if [[ -z "${SESSION_CWD}" ]]; then
  SESSION_CWD="${HOME}"
  log "WARN: cwd not found in transcript; using HOME"
fi

REPO_ROOT="$(git -C "${SESSION_CWD}" rev-parse --show-toplevel 2>/dev/null || echo "")"
if [[ -n "${REPO_ROOT}" ]]; then
  PROJECT_NAME="$(basename "${REPO_ROOT}")"
elif [[ "${SESSION_CWD}" == "${HOME}" || "${SESSION_CWD}" == "${HOME}/" ]]; then
  PROJECT_NAME="home"
else
  PROJECT_NAME="$(basename "${SESSION_CWD}")"
fi

GIT_BRANCH="$(grep '"role":"user"' "${TRANSCRIPT_PATH}" | head -1 | jq -r '.gitBranch // ""' 2>/dev/null || echo "")"

# --- Triage 3: Shared user-configured exclusions ---
EXCLUSION_CHECKER="${WORK_WIKI}/.system/scripts/session_exclusions.py"
if [[ -f "${EXCLUSION_CHECKER}" ]]; then
  set +e
  EXCLUSION_RESULT="$(python3 "${EXCLUSION_CHECKER}" \
    --work-wiki "${WORK_WIKI}" \
    --source claude \
    --session-id "${SESSION_ID}" \
    --transcript-path "${TRANSCRIPT_PATH}" \
    --cwd "${SESSION_CWD}" \
    --project-name "${PROJECT_NAME}" \
    --git-branch "${GIT_BRANCH}" \
    --json 2>&1)"
  EXCLUSION_STATUS=$?
  set -e
  if [[ "${EXCLUSION_STATUS}" -eq 0 ]]; then
    RULE_ID="$(echo "${EXCLUSION_RESULT}" | jq -r '.rule_id // "unknown"' 2>/dev/null || echo "unknown")"
    REASON="$(echo "${EXCLUSION_RESULT}" | jq -r '.reason // ""' 2>/dev/null || echo "")"
    log "SKIP: excluded by session-exclusions rule=${RULE_ID}${REASON:+ reason=${REASON}}"
    exit 0
  elif [[ "${EXCLUSION_STATUS}" -ne 1 ]]; then
    log "ERROR: exclusion config check failed: ${EXCLUSION_RESULT}"
    exit 0
  fi
fi

# Snapshot the current resume cursor (informational; synthesizer reads live cursor).
STATE_FILE="${WORK_WIKI}/.system/state/sessions/${SESSION_ID}.uuid"
LAST_CURSOR="none"
if [[ -f "${STATE_FILE}" ]]; then
  LAST_CURSOR="$(cat "${STATE_FILE}")"
fi

# --- Enqueue: write pending file atomically (tmp-then-mv in same dir) ---
ENQUEUED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
ENQUEUE_TS="$(date '+%Y%m%dT%H%M%S')"
PENDING_FILE="${PENDING_DIR}/${SESSION_ID}-${ENQUEUE_TS}.json"
TMP_FILE="${PENDING_DIR}/.${SESSION_ID}-${ENQUEUE_TS}.json.tmp"

if ! jq -n \
  --arg source "claude" \
  --arg session_id "${SESSION_ID}" \
  --arg transcript_path "${TRANSCRIPT_PATH}" \
  --arg session_cwd "${SESSION_CWD}" \
  --arg project_name "${PROJECT_NAME}" \
  --arg git_branch "${GIT_BRANCH}" \
  --arg cursor_type "uuid" \
  --arg last_cursor "${LAST_CURSOR}" \
  --arg enqueued_at "${ENQUEUED_AT}" \
  '{source:$source,session_id:$session_id,transcript_path:$transcript_path,session_cwd:$session_cwd,project_name:$project_name,git_branch:$git_branch,cursor_type:$cursor_type,last_cursor:$last_cursor,enqueued_at:$enqueued_at}' \
  > "${TMP_FILE}" 2>>"${LOG_FILE}"; then
  log "ERROR: Failed to write pending tmp file"
  rm -f "${TMP_FILE}"
  exit 0
fi
mv "${TMP_FILE}" "${PENDING_FILE}"
log "ENQUEUED ${SESSION_ID:0:8} project=${PROJECT_NAME} branch=${GIT_BRANCH:-none}"

# --- Decide whether to fire synthesizer now ---
SHOULD_FIRE=0
FIRE_REASON=""

PENDING_COUNT="$(find "${PENDING_DIR}" -maxdepth 1 -name '*.json' -not -name '.*' 2>/dev/null | wc -l | tr -d ' ')"
if [[ "${PENDING_COUNT}" -ge "${MAX_PENDING}" ]]; then
  SHOULD_FIRE=1
  FIRE_REASON="count=${PENDING_COUNT} >= ${MAX_PENDING}"
fi

if [[ "${SHOULD_FIRE}" -eq 0 ]]; then
  # Find oldest pending mtime
  OLDEST_MTIME=0
  NOW="$(date '+%s')"
  for f in "${PENDING_DIR}"/*.json; do
    [[ -f "${f}" ]] || continue
    M="$(file_mtime "${f}")"
    if [[ "${OLDEST_MTIME}" -eq 0 || "${M}" -lt "${OLDEST_MTIME}" ]]; then
      OLDEST_MTIME="${M}"
    fi
  done
  if [[ "${OLDEST_MTIME}" -gt 0 ]]; then
    AGE_SEC=$(( NOW - OLDEST_MTIME ))
    THRESHOLD_SEC=$(( MAX_AGE_HOURS * 3600 ))
    if [[ "${AGE_SEC}" -ge "${THRESHOLD_SEC}" ]]; then
      SHOULD_FIRE=1
      FIRE_REASON="oldest_age=${AGE_SEC}s >= ${THRESHOLD_SEC}s"
    fi
  fi
fi

if [[ "${SHOULD_FIRE}" -ne 1 ]]; then
  log "QUEUED only (count=${PENDING_COUNT}, threshold=${MAX_PENDING}); waiting for trigger or daily floor"
  exit 0
fi

if [[ ! -x "${SYNTHESIZER}" && ! -f "${SYNTHESIZER}" ]]; then
  log "ERROR: Synthesizer not found at ${SYNTHESIZER}"
  exit 0
fi

SYNTH_LOG="${LOG_DIR}/wiki-synthesizer.log"
nohup bash "${SYNTHESIZER}" >> "${SYNTH_LOG}" 2>&1 &
log "FIRED synthesizer PID=$! reason=${FIRE_REASON}"
exit 0
