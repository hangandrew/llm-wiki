#!/usr/bin/env bash
# Recall hook: fires on SessionStart. Surfaces the worklog's in-flight
# workstreams for the current repo so a new session resumes with context.
# Reads worklog/live/*.md, filters to the session's project (or current git
# branch), and injects a compact board into the session via additionalContext.
# MUST always exit 0 and stay silent when there's nothing to surface — never
# blocks or noisily interrupts session start.

set -euo pipefail

WORK_WIKI="${WORK_WIKI_DIR:-${WORK_TRACKER_DIR:-${HOME}/work-wiki}}"
LIVE_DIR="${WORK_WIKI}/worklog/live"
LOG_DIR="${HOME}/.claude/logs"
LOG_FILE="${LOG_DIR}/wiki-session-start.log"

mkdir -p "${LOG_DIR}" 2>/dev/null || true
ts() { date '+%Y-%m-%dT%H:%M:%S'; }
log() { echo "[$(ts)] [start-hook] $*" >> "${LOG_FILE}" 2>/dev/null || true; }

# Nothing to do if the worklog isn't present yet.
[[ -d "${LIVE_DIR}" ]] || exit 0

# --- Read hook payload ---
INPUT="$(cat 2>/dev/null || true)"
CWD="$(printf '%s' "${INPUT}" | jq -r '.cwd // empty' 2>/dev/null || true)"
[[ -z "${CWD}" ]] && CWD="${PWD}"

# --- Derive project name + branch (mirror wiki-session-end.sh) ---
REPO_ROOT="$(git -C "${CWD}" rev-parse --show-toplevel 2>/dev/null || echo "")"
if [[ -n "${REPO_ROOT}" ]]; then
  PROJECT_NAME="$(basename "${REPO_ROOT}")"
elif [[ "${CWD}" == "${HOME}" || "${CWD}" == "${HOME}/" ]]; then
  PROJECT_NAME="home"
else
  PROJECT_NAME="$(basename "${CWD}")"
fi
GIT_BRANCH="$(git -C "${CWD}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"

# --- Frontmatter / field extractors (single file) ---
field() {  # field <file> <key>  → first "key: value" in the frontmatter
  grep -m1 "^$2:" "$1" 2>/dev/null | sed "s/^$2:[[:space:]]*//" || true
}

# --- Collect matching live items ---
shopt -s nullglob
LINES=""
COUNT=0
for f in "${LIVE_DIR}"/*.md; do
  proj="$(field "$f" project)"
  keys="$(field "$f" keys)"
  # Match on project, or on the current branch appearing in keys (branch:<name>).
  match=0
  [[ -n "${PROJECT_NAME}" && "${proj}" == "${PROJECT_NAME}" ]] && match=1
  if [[ "${match}" -eq 0 && -n "${GIT_BRANCH}" ]]; then
    printf '%s' "${keys}" | grep -qF "branch:${GIT_BRANCH}" && match=1
  fi
  [[ "${match}" -eq 1 ]] || continue

  slug="$(field "$f" slug)"; [[ -z "${slug}" ]] && slug="$(basename "$f" .md)"
  status="$(field "$f" status)"; [[ -z "${status}" ]] && status="active"
  next="$(grep -m1 '^\*\*Next action:\*\*' "$f" 2>/dev/null | sed 's/^\*\*Next action:\*\*[[:space:]]*//' || true)"
  rel="worklog/live/$(basename "$f")"
  LINES+="- [${status}] ${slug} — ${next:-(no next action recorded)} (${rel})"$'\n'
  COUNT=$((COUNT + 1))
done
shopt -u nullglob

if [[ "${COUNT}" -eq 0 ]]; then
  log "no live workstreams for project=${PROJECT_NAME} branch=${GIT_BRANCH:-none}; silent"
  exit 0
fi

CONTEXT="Active worklog for **${PROJECT_NAME}** (in-flight work; see ${WORK_WIKI}/worklog/):
${LINES}
Read the linked live/<slug>.md for status, blockers, and links. Update them as work progresses per worklog/WORKLOG.md."

# Emit as SessionStart additionalContext (JSON-escaped via jq).
jq -n --arg ctx "${CONTEXT}" \
  '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}' 2>/dev/null \
  || true
log "surfaced ${COUNT} workstream(s) for project=${PROJECT_NAME} branch=${GIT_BRANCH:-none}"
exit 0
