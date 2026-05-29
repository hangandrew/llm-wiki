#!/usr/bin/env bash
# Poll Codex's local thread index, enqueue idle changed rollout JSONL files,
# and opportunistically fire the shared wiki synthesizer.

set -euo pipefail

MAX_PENDING="${WORK_WIKI_MAX_PENDING:-5}"
MAX_AGE_HOURS="${WORK_WIKI_MAX_AGE_HOURS:-6}"

WORK_WIKI="${WORK_WIKI_DIR:-${WORK_TRACKER_DIR:-${HOME}/work-wiki}}"
SCRIPT_DIR="${WORK_WIKI}/.system/scripts"
SYNTHESIZER="${WORK_WIKI}/.system/hooks/wiki-synthesizer.sh"
PENDING_DIR="${WORK_WIKI}/.system/state/pending"
LOG_DIR="${HOME}/.claude/logs"
LOG_FILE="${LOG_DIR}/wiki-codex-ingest.log"

mkdir -p "${LOG_DIR}" "${PENDING_DIR}"

ts() { date '+%Y-%m-%dT%H:%M:%S'; }
log() { echo "[$(ts)] [codex-ingest] $*" >> "${LOG_FILE}"; }

file_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
}

log "=== Starting Codex ingest ==="

if [[ ! -f "${SCRIPT_DIR}/codex-extract.py" ]]; then
  log "ERROR: extractor missing at ${SCRIPT_DIR}/codex-extract.py"
  exit 1
fi

SUMMARY_JSON="$(python3 "${SCRIPT_DIR}/codex-extract.py" --work-wiki "${WORK_WIKI}" --enqueue --json 2>>"${LOG_FILE}")"
log "extract ${SUMMARY_JSON}"

SHOULD_FIRE=0
FIRE_REASON=""
PENDING_COUNT="$(find "${PENDING_DIR}" -maxdepth 1 -name '*.json' -not -name '.*' 2>/dev/null | wc -l | tr -d ' ')"
if [[ "${PENDING_COUNT}" -ge "${MAX_PENDING}" ]]; then
  SHOULD_FIRE=1
  FIRE_REASON="count=${PENDING_COUNT} >= ${MAX_PENDING}"
fi

if [[ "${SHOULD_FIRE}" -eq 0 ]]; then
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
  exit 1
fi

SYNTH_LOG="${LOG_DIR}/wiki-synthesizer.log"
nohup bash "${SYNTHESIZER}" >> "${SYNTH_LOG}" 2>&1 &
log "FIRED synthesizer PID=$! reason=${FIRE_REASON}"
