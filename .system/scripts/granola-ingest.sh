#!/usr/bin/env bash
# Daily Granola ingest. Polls Granola's Personal API for notes updated since
# the last successful run, writes a temporary JSONL bundle with note details
# and transcripts, then spawns the configured headless agent to fold durable
# meeting signal into the wiki.
#
# Process-and-discard: raw Granola note bodies and transcripts live only in
# /tmp for the duration of the run. Durable state stores cursor + metadata.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_WIKI="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Load credentials from the install-managed secrets file. launchd jobs don't
# inherit an interactive shell, so this is how the key reaches the scheduled
# run. Only fills variables that are currently empty — a real environment
# variable (e.g. a manual `WORK_WIKI_GRANOLA_API_KEY=… ./granola-ingest.sh`) wins.
load_secrets_file() {
  local f="${WORK_WIKI_SECRETS_FILE:-${HOME}/.config/work-wiki/secrets.env}"
  [[ -f "${f}" ]] || return 0
  local line key val
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"   # left-trim
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    line="${line#export }"
    [[ "${line}" != *=* ]] && continue
    key="${line%%=*}"; key="${key//[[:space:]]/}"
    val="${line#*=}"
    val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
    [[ -z "${!key:-}" ]] && export "${key}=${val}"
  done < "${f}"
}
load_secrets_file

TEMPLATE_FILE="${WORK_WIKI}/.system/prompts/wiki-update-granola.md"
EXTRACTOR="${WORK_WIKI}/.system/scripts/granola-extract.py"
RUNNER="${WORK_WIKI}/.system/scripts/headless-agent-run.sh"
CURSOR_FILE="${WORK_WIKI}/.system/state/granola-ingest-cursor.json"
LOCK_DIR="${WORK_WIKI}/.system/state/granola-ingest.lock"
STATE_DIR="${WORK_WIKI}/.system/state"
LOG_DIR="${HOME}/.claude/logs"
LOG_FILE="${LOG_DIR}/granola-ingest.log"

mkdir -p "${STATE_DIR}" "${LOG_DIR}"

ts() { date '+%Y-%m-%dT%H:%M:%S'; }
log() { echo "[$(ts)] [granola-ingest] $*" >> "${LOG_FILE}"; }

FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    -h|--help)
      cat <<EOF
Usage: granola-ingest.sh [--force]
  --force   Bypass the lock file (use if a stale lock is wedged)
EOF
      exit 0
      ;;
    *)
      echo "Unknown argument: ${arg}" >&2
      exit 2
      ;;
  esac
done

[[ -f "${TEMPLATE_FILE}" ]] || { echo "ERROR: prompt template not found at ${TEMPLATE_FILE}" >&2; log "ABORT: missing template ${TEMPLATE_FILE}"; exit 1; }
[[ -f "${EXTRACTOR}" ]] || { echo "ERROR: extractor not found at ${EXTRACTOR}" >&2; log "ABORT: missing extractor ${EXTRACTOR}"; exit 1; }
[[ -n "${WORK_WIKI_GRANOLA_API_KEY:-}" ]] || { echo "ERROR: WORK_WIKI_GRANOLA_API_KEY is required" >&2; log "ABORT: missing WORK_WIKI_GRANOLA_API_KEY"; exit 2; }

if [[ "$FORCE" -eq 1 ]]; then
  rmdir "$LOCK_DIR" 2>/dev/null || true
fi
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  log "SKIP: another granola-ingest is running (lock: $LOCK_DIR)"
  exit 0
fi

BUNDLE_FILE="$(mktemp /tmp/granola-ingest-bundle.XXXXXX.jsonl)"
STATE_BUNDLE_FILE="$(mktemp /tmp/granola-ingest-state.XXXXXX.jsonl)"
PROMPT_FILE="$(mktemp /tmp/granola-ingest-prompt.XXXXXX)"
cleanup() {
  rmdir "$LOCK_DIR" 2>/dev/null || true
  rm -f "${BUNDLE_FILE}" "${STATE_BUNDLE_FILE}" "${PROMPT_FILE}"
}
trap cleanup EXIT INT TERM

log "=== Starting granola-ingest run ==="

LOOKBACK_HOURS="${WORK_WIKI_GRANOLA_LOOKBACK_HOURS:-24}"
OVERLAP_MINUTES="${WORK_WIKI_GRANOLA_OVERLAP_MINUTES:-15}"
PAGE_SIZE="${WORK_WIKI_GRANOLA_PAGE_SIZE:-30}"
RUN_START_TS="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
TODAY_DATE="$(date '+%Y-%m-%d')"

SINCE_TS="$(
  CURSOR_FILE="${CURSOR_FILE}" LOOKBACK_HOURS="${LOOKBACK_HOURS}" OVERLAP_MINUTES="${OVERLAP_MINUTES}" python3 <<'PYEOF'
import json
import os
from datetime import datetime, timedelta, timezone

def parse_iso(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))

now = datetime.now(timezone.utc)
cursor_file = os.environ["CURSOR_FILE"]
lookback = int(os.environ["LOOKBACK_HOURS"])
overlap = int(os.environ["OVERLAP_MINUTES"])
base = now - timedelta(hours=lookback)
try:
    with open(cursor_file) as f:
        payload = json.load(f)
    raw = payload.get("last_successful_run_start")
    if raw:
        base = parse_iso(raw) - timedelta(minutes=overlap)
except Exception:
    pass
print(base.strftime("%Y-%m-%dT%H:%M:%SZ"))
PYEOF
)"

log "Run start: ${RUN_START_TS}; updated_after=${SINCE_TS}; page_size=${PAGE_SIZE}"

EXTRACT_LOG="${LOG_DIR}/granola-extract.log"
EXTRACT_JSON="$(python3 "${EXTRACTOR}" \
  --work-wiki "${WORK_WIKI}" \
  extract \
  --updated-after "${SINCE_TS}" \
  --run-start "${RUN_START_TS}" \
  --page-size "${PAGE_SIZE}" \
  --bundle "${BUNDLE_FILE}" \
  --state-bundle "${STATE_BUNDLE_FILE}" \
  2>>"${EXTRACT_LOG}")"
log "extract ${EXTRACT_JSON}"
RETRY_COUNT="$(EXTRACT_JSON="${EXTRACT_JSON}" python3 <<'PYEOF'
import json
import os
try:
    print(int(json.loads(os.environ["EXTRACT_JSON"]).get("retry", 0)))
except Exception:
    print(0)
PYEOF
)"

CHANGED_COUNT="$(wc -l < "${BUNDLE_FILE}" | tr -d ' ')"
if [[ "${CHANGED_COUNT}" -eq 0 ]]; then
  if [[ "${RETRY_COUNT}" -eq 0 ]]; then
    TMP_CURSOR="${CURSOR_FILE}.tmp"
    printf '{"last_successful_run_start":"%s","updated_after":"%s","note_count":0}\n' "${RUN_START_TS}" "${SINCE_TS}" > "${TMP_CURSOR}"
    mv "${TMP_CURSOR}" "${CURSOR_FILE}"
    log "No changed notes; cursor advanced → ${RUN_START_TS}"
  else
    log "No changed notes but ${RETRY_COUNT} note(s) need retry; cursor NOT advanced"
  fi
  log "=== Done (exit=0) ==="
  exit 0
fi

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

export TEMPLATE_FILE PROMPT_FILE WORK_WIKI BUNDLE_FILE SINCE_TS RUN_START_TS TODAY_DATE \
       EXISTING_PROJECTS EXISTING_CONCEPTS CHANGED_COUNT

python3 <<'PYEOF'
import os
from string import Template

with open(os.environ["TEMPLATE_FILE"]) as f:
    tpl = Template(f.read())
rendered = tpl.safe_substitute(
    WORK_WIKI=os.environ["WORK_WIKI"],
    BUNDLE_FILE=os.environ["BUNDLE_FILE"],
    SINCE_TS=os.environ["SINCE_TS"],
    RUN_START_TS=os.environ["RUN_START_TS"],
    TODAY_DATE=os.environ["TODAY_DATE"],
    EXISTING_PROJECTS=os.environ["EXISTING_PROJECTS"],
    EXISTING_CONCEPTS=os.environ["EXISTING_CONCEPTS"],
    CHANGED_COUNT=os.environ["CHANGED_COUNT"],
)
with open(os.environ["PROMPT_FILE"], "w") as f:
    f.write(rendered)
PYEOF

PROVIDER="$("${RUNNER}" --job granola --print-provider)"
log "Invoking ${PROVIDER} (granola-ingest) for ${CHANGED_COUNT} note(s)..."
EX=0
"${RUNNER}" \
  --job granola \
  --prompt-file "${PROMPT_FILE}" \
  --allowed-claude-tools "Read,Write,Edit,Glob,Grep,Bash" \
  --codex-writable-dir "${WORK_WIKI}" \
  --log-label "granola-ingest" \
  >> /dev/null 2>&1 || EX=$?
log "${PROVIDER} exited: ${EX}"

if [[ "${EX}" -eq 0 ]]; then
  python3 "${EXTRACTOR}" --work-wiki "${WORK_WIKI}" commit-state --state-bundle "${STATE_BUNDLE_FILE}" >> "${LOG_FILE}" 2>&1
  if [[ "${RETRY_COUNT}" -eq 0 ]]; then
    TMP_CURSOR="${CURSOR_FILE}.tmp"
    printf '{"last_successful_run_start":"%s","updated_after":"%s","note_count":%s}\n' "${RUN_START_TS}" "${SINCE_TS}" "${CHANGED_COUNT}" > "${TMP_CURSOR}"
    mv "${TMP_CURSOR}" "${CURSOR_FILE}"
    log "Cursor advanced → ${RUN_START_TS}; committed ${CHANGED_COUNT} note state(s)"
  else
    log "Committed ${CHANGED_COUNT} note state(s), but ${RETRY_COUNT} note(s) need retry; cursor NOT advanced"
  fi
else
  log "WARN: agent exited non-zero; cursor and note state NOT advanced (will retry same window next run)"
fi

log "=== Done (exit=${EX}) ==="
exit 0
