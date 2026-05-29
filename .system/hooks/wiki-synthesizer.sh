#!/usr/bin/env bash
# Batched wiki synthesizer. Reads all pending session entries, dedupes by
# source + session_id, classifies each by new-tail size, runs ONE batched
# headless provider invocation for the small entries and a DEDICATED run per large entry, then
# advances per-session cursors and commits once.
#
# Triggered by:
#   - .system/hooks/wiki-session-end.sh when MAX_PENDING or MAX_AGE_HOURS hits
#   - launchd daily plist (if installed)
#   - manual invocation: bash wiki-synthesizer.sh [--force]
#
# Configuration env vars:
#   WORK_WIKI_DIR                 path to the wiki repo (default: ~/work-wiki)
#   WORK_WIKI_GIT_NAME / EMAIL    author for auto-commits
#   WORK_WIKI_AUTO_PUSH           "1"/"true" to push origin/main after commit
#   WORK_WIKI_LARGE_TAIL_USER_MSGS  threshold for "large" sessions (default 50)
#   WORK_WIKI_LARGE_TAIL_BYTES      threshold for "large" sessions (default 500000)
#
# Backward-compat: WORK_TRACKER_* vars accepted as fallback.

set -euo pipefail

# --- Config ---
LARGE_TAIL_USER_MSGS="${WORK_WIKI_LARGE_TAIL_USER_MSGS:-50}"
LARGE_TAIL_BYTES="${WORK_WIKI_LARGE_TAIL_BYTES:-500000}"

WORK_WIKI="${WORK_WIKI_DIR:-${WORK_TRACKER_DIR:-${HOME}/work-wiki}}"
GIT_USER_NAME="${WORK_WIKI_GIT_NAME:-${WORK_TRACKER_GIT_NAME:-$(git config --global user.name 2>/dev/null || echo "")}}"
GIT_USER_EMAIL="${WORK_WIKI_GIT_EMAIL:-${WORK_TRACKER_GIT_EMAIL:-$(git config --global user.email 2>/dev/null || echo "")}}"
AUTO_PUSH="${WORK_WIKI_AUTO_PUSH:-${WORK_TRACKER_AUTO_PUSH:-0}}"

PENDING_DIR="${WORK_WIKI}/.system/state/pending"
SESSIONS_DIR="${WORK_WIKI}/.system/state/sessions"
CODEX_SESSIONS_DIR="${WORK_WIKI}/.system/state/codex-sessions"
LOCK_DIR="${WORK_WIKI}/.system/state/synthesizer.lock"
LOG_DIR="${HOME}/.claude/logs"
LOG_FILE="${LOG_DIR}/wiki-synthesizer.log"
RUNNER="${WORK_WIKI}/.system/scripts/headless-agent-run.sh"

mkdir -p "${PENDING_DIR}" "${SESSIONS_DIR}" "${CODEX_SESSIONS_DIR}" "${LOG_DIR}"

ts() { date '+%Y-%m-%dT%H:%M:%S'; }
log() { echo "[$(ts)] [synth] $*" >> "${LOG_FILE}"; }

FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    -h|--help)
      cat <<EOF
Usage: wiki-synthesizer.sh [--force]
  --force   Bypass the lock file (use if a stale lock is wedged)
EOF
      exit 0
      ;;
  esac
done

# --- Lock ---
if [[ "$FORCE" -eq 1 ]]; then
  rmdir "$LOCK_DIR" 2>/dev/null || true
fi
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  log "SKIP: another synthesizer is running (lock: $LOCK_DIR)"
  exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM

log "=== Starting synth run ==="

# --- First-run init ---
if [[ ! -d "${WORK_WIKI}/.git" ]]; then
  log "Initializing wiki repo at ${WORK_WIKI}..."
  git init "${WORK_WIKI}"
  [[ -n "${GIT_USER_EMAIL}" ]] && git -C "${WORK_WIKI}" config user.email "${GIT_USER_EMAIL}"
  [[ -n "${GIT_USER_NAME}"  ]] && git -C "${WORK_WIKI}" config user.name  "${GIT_USER_NAME}"
fi

# --- Discover pending ---
shopt -s nullglob
PENDING_FILES=("${PENDING_DIR}"/*.json)
shopt -u nullglob

if [[ "${#PENDING_FILES[@]}" -eq 0 ]]; then
  log "No pending sessions; exiting."
  exit 0
fi
log "Found ${#PENDING_FILES[@]} pending file(s)"

# --- Dedupe by source + session_id (keep latest enqueued_at; remove the others) ---
# Bash 3.2-compatible (no associative arrays): build a TSV of <enq>\t<key>\t<file>,
# sort descending by enq, then for each source/session key keep the first occurrence.
INDEX_FILE="$(mktemp /tmp/wiki-synth-index.XXXXXX)"
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true; rm -f "$INDEX_FILE"' EXIT INT TERM

for f in "${PENDING_FILES[@]}"; do
  source="$(jq -r '.source // "claude"' "$f" 2>/dev/null || echo "claude")"
  sid="$(jq -r '.session_id // ""' "$f" 2>/dev/null || echo "")"
  enq="$(jq -r '.enqueued_at // ""' "$f" 2>/dev/null || echo "")"
  if [[ -z "$sid" || -z "$enq" ]]; then
    log "WARN: malformed pending file: $f (removing)"
    rm -f "$f"
    continue
  fi
  printf '%s\t%s:%s\t%s\n' "$enq" "$source" "$sid" "$f" >> "$INDEX_FILE"
done

declare -a DEDUP_FILES=()
SEEN_KEYS_FILE="$(mktemp /tmp/wiki-synth-seen.XXXXXX)"
# Sort by enqueued_at descending so the newest entry per source/session wins.
sort -r "$INDEX_FILE" > "${INDEX_FILE}.sorted"
while IFS=$'\t' read -r enq key f; do
  if grep -qxF "$key" "$SEEN_KEYS_FILE" 2>/dev/null; then
    log "DEDUPE ${key}: drop older $(basename "$f") (kept newer enqueue)"
    rm -f "$f"
  else
    echo "$key" >> "$SEEN_KEYS_FILE"
    DEDUP_FILES+=("$f")
  fi
done < "${INDEX_FILE}.sorted"
rm -f "$INDEX_FILE" "${INDEX_FILE}.sorted" "$SEEN_KEYS_FILE"

if [[ "${#DEDUP_FILES[@]}" -eq 0 ]]; then
  log "No valid pending entries after dedup; exiting."
  exit 0
fi

# --- Drop orphans whose transcripts no longer exist ---
declare -a VALID_FILES=()
for f in "${DEDUP_FILES[@]}"; do
  tp="$(jq -r '.transcript_path' "$f")"
  if [[ ! -f "$tp" ]]; then
    sid="$(jq -r '.session_id' "$f")"
    log "ORPHAN ${sid:0:8}: transcript missing ($tp); removing pending"
    rm -f "$f"
    continue
  fi
  VALID_FILES+=("$f")
done

if [[ "${#VALID_FILES[@]}" -eq 0 ]]; then
  log "No pending entries with valid transcripts; exiting."
  exit 0
fi

pending_source() {
  jq -r '.source // "claude"' "$1" 2>/dev/null || echo "claude"
}

pending_cursor_type() {
  local f="$1" source
  source="$(pending_source "$f")"
  jq -r --arg fallback "$([[ "$source" == "codex" ]] && echo line || echo uuid)" '.cursor_type // $fallback' "$f" 2>/dev/null
}

state_file_for() {
  local source="$1" sid="$2"
  if [[ "$source" == "codex" ]]; then
    echo "${CODEX_SESSIONS_DIR}/${sid}.line"
  else
    echo "${SESSIONS_DIR}/${sid}.uuid"
  fi
}

live_cursor_for() {
  local source="$1" sid="$2" state_file
  state_file="$(state_file_for "$source" "$sid")"
  if [[ -f "$state_file" ]]; then
    cat "$state_file"
  else
    if [[ "$source" == "codex" ]]; then echo "0"; else echo "none"; fi
  fi
}

# --- Helpers: tail-size computations relative to LIVE cursor ---
claude_tail_user_msgs() {
  local transcript="$1" cursor="$2"
  jq -s --arg cursor "$cursor" '
    (if $cursor == "none" or $cursor == "" then .
     else (map(.uuid) | index($cursor)) as $idx
          | if $idx == null then . else .[($idx + 1):] end
     end)
    | map(select(
        .type == "user"
        and (.isMeta // false | not)
        and (.isSidechain // false | not)
        and ((.message.content | type) != "string"
             or ((.message.content | startswith("<local-command-stdout>") | not)
                 and (.message.content | startswith("<local-command-caveat>") | not)
                 and (.message.content | test("^<command-name>/(exit|clear|logout|compact)") | not)))
      )) | length
  ' "$transcript" 2>/dev/null || echo 0
}

claude_tail_bytes() {
  local transcript="$1" cursor="$2"
  jq -s -c --arg cursor "$cursor" '
    (if $cursor == "none" or $cursor == "" then .
     else (map(.uuid) | index($cursor)) as $idx
          | if $idx == null then . else .[($idx + 1):] end
     end)
    | .[]
  ' "$transcript" 2>/dev/null | wc -c | tr -d ' '
}

codex_tail_user_msgs() {
  local transcript="$1" cursor="${2:-0}"
  jq -s --argjson cursor "${cursor:-0}" '
    .[$cursor:]
    | map(select(
        .type == "response_item"
        and (.payload.type // "") == "message"
        and (.payload.role // "") == "user"
      )) | length
  ' "$transcript" 2>/dev/null || echo 0
}

codex_tail_bytes() {
  local transcript="$1" cursor="${2:-0}"
  awk -v start="$(( ${cursor:-0} + 1 ))" 'NR >= start { print }' "$transcript" 2>/dev/null | wc -c | tr -d ' '
}

tail_user_msgs() {
  local source="$1" transcript="$2" cursor="$3"
  if [[ "$source" == "codex" ]]; then
    codex_tail_user_msgs "$transcript" "$cursor"
  else
    claude_tail_user_msgs "$transcript" "$cursor"
  fi
}

tail_bytes() {
  local source="$1" transcript="$2" cursor="$3"
  if [[ "$source" == "codex" ]]; then
    codex_tail_bytes "$transcript" "$cursor"
  else
    claude_tail_bytes "$transcript" "$cursor"
  fi
}

latest_uuid() {
  jq -r 'select(.uuid) | .uuid' "$1" 2>/dev/null | tail -1
}

latest_cursor() {
  local source="$1" transcript="$2"
  if [[ "$source" == "codex" ]]; then
    wc -l < "$transcript" | tr -d ' '
  else
    latest_uuid "$transcript"
  fi
}

# --- Classify ---
declare -a SMALL_FILES=()
declare -a LARGE_FILES=()
for f in "${VALID_FILES[@]}"; do
  source="$(pending_source "$f")"
  sid="$(jq -r '.session_id' "$f")"
  tp="$(jq -r '.transcript_path' "$f")"
  cursor="$(live_cursor_for "$source" "$sid")"
  msgs="$(tail_user_msgs "$source" "$tp" "$cursor")"
  bytes="$(tail_bytes "$source" "$tp" "$cursor")"
  if [[ "$msgs" -gt "$LARGE_TAIL_USER_MSGS" || "$bytes" -gt "$LARGE_TAIL_BYTES" ]]; then
    log "[large] ${source}:${sid:0:8} — ${msgs} msgs / ${bytes} bytes → dedicated run"
    LARGE_FILES+=("$f")
  else
    log "[small] ${source}:${sid:0:8} — ${msgs} msgs / ${bytes} bytes"
    SMALL_FILES+=("$f")
  fi
done

# --- Snapshot existing entity slugs for prompts ---
existing_projects() {
  find "${WORK_WIKI}/wiki/entities/projects" -mindepth 1 -maxdepth 1 -name '*.md' 2>/dev/null \
    | xargs -I {} basename {} .md | sort | sed 's/^/- /'
}
existing_concepts() {
  find "${WORK_WIKI}/wiki/concepts" -mindepth 1 -maxdepth 1 -name '*.md' 2>/dev/null \
    | xargs -I {} basename {} .md | sort | sed 's/^/- /'
}
EXISTING_PROJECTS="$(existing_projects)"; [[ -z "$EXISTING_PROJECTS" ]] && EXISTING_PROJECTS="(none yet)"
EXISTING_CONCEPTS="$(existing_concepts)"; [[ -z "$EXISTING_CONCEPTS" ]] && EXISTING_CONCEPTS="(none yet)"

DATE_STR="$(date '+%Y-%m-%d')"
TIME_STR="$(date '+%H:%M')"

declare -a SUCCESS_PROJECTS=()
SUCCESS_COUNT=0
record_success_project() {
  local p="$1" existing
  for existing in "${SUCCESS_PROJECTS[@]:-}"; do
    [[ "$existing" == "$p" ]] && return
  done
  SUCCESS_PROJECTS+=("$p")
}

# --- Small-batch run ---
if [[ "${#SMALL_FILES[@]}" -gt 0 ]]; then
  log "BATCH: synthesizing ${#SMALL_FILES[@]} small session(s)"
  TEMPLATE_FILE="${WORK_WIKI}/.system/prompts/wiki-synthesize-pending.md"

  if [[ ! -f "$TEMPLATE_FILE" ]]; then
    log "ERROR: batch prompt template not found at $TEMPLATE_FILE; skipping batch"
  else
    SESSIONS_BLOCK=""
    for f in "${SMALL_FILES[@]}"; do
      source="$(pending_source "$f")"
      cursor_type="$(pending_cursor_type "$f")"
      sid="$(jq -r '.session_id' "$f")"
      proj="$(jq -r '.project_name' "$f")"
      branch="$(jq -r '.git_branch // ""' "$f")"
      tp="$(jq -r '.transcript_path' "$f")"
      enq="$(jq -r '.enqueued_at' "$f")"
      cursor="$(live_cursor_for "$source" "$sid")"
      SESSIONS_BLOCK+="### Session ${source}:${sid:0:8}
- Source: ${source}
- Session ID: ${sid}
- Project: ${proj}
- Git branch: ${branch:-unknown}
- Enqueued at: ${enq}
- Transcript: ${tp}
- Cursor type: ${cursor_type}
- Last cursor processed: ${cursor}

"
    done

    PROMPT_FILE="$(mktemp /tmp/wiki-synth-batch.XXXXXX)"
    export TEMPLATE_FILE PROMPT_FILE WORK_WIKI DATE_STR TIME_STR \
           SESSIONS_BLOCK EXISTING_PROJECTS EXISTING_CONCEPTS
    export SESSION_COUNT="${#SMALL_FILES[@]}"

    python3 <<'PYEOF'
import os
from string import Template
with open(os.environ["TEMPLATE_FILE"]) as f:
    tpl = Template(f.read())
rendered = tpl.safe_substitute(
    WORK_WIKI=os.environ.get("WORK_WIKI", ""),
    DATE_STR=os.environ.get("DATE_STR", ""),
    TIME_STR=os.environ.get("TIME_STR", ""),
    SESSIONS_BLOCK=os.environ.get("SESSIONS_BLOCK", ""),
    SESSION_COUNT=os.environ.get("SESSION_COUNT", ""),
    EXISTING_PROJECTS=os.environ.get("EXISTING_PROJECTS", ""),
    EXISTING_CONCEPTS=os.environ.get("EXISTING_CONCEPTS", ""),
)
with open(os.environ["PROMPT_FILE"], "w") as f:
    f.write(rendered)
PYEOF

    PROVIDER="$("${RUNNER}" --job session --print-provider)"
    log "Invoking ${PROVIDER} (batch)..."
    BATCH_EXIT=0
    "${RUNNER}" \
      --job session \
      --prompt-file "$PROMPT_FILE" \
      --allowed-claude-tools "Bash,Read,Write,Edit,Glob,Grep" \
      --codex-writable-dir "${WORK_WIKI}" \
      --log-label "wiki-synth-batch" \
      >> /dev/null 2>&1 || BATCH_EXIT=$?
    log "${PROVIDER} (batch) exited: $BATCH_EXIT"
    rm -f "$PROMPT_FILE"

    if [[ "$BATCH_EXIT" -eq 0 ]]; then
      for f in "${SMALL_FILES[@]}"; do
        source="$(pending_source "$f")"
        sid="$(jq -r '.session_id' "$f")"
        proj="$(jq -r '.project_name' "$f")"
        tp="$(jq -r '.transcript_path' "$f")"
        L="$(latest_cursor "$source" "$tp")"
        if [[ -n "$L" ]]; then
          echo "$L" > "$(state_file_for "$source" "$sid")"
          log "  cursor advanced ${source}:${sid:0:8} → $L"
        fi
        rm -f "$f"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        record_success_project "$proj"
      done
    else
      log "WARN: batch run failed; leaving small pending files in place"
    fi
  fi
fi

# --- Large entries: one dedicated run each (sequential) ---
if [[ "${#LARGE_FILES[@]}" -gt 0 ]]; then
  PER_TEMPLATE="${WORK_WIKI}/.system/prompts/wiki-update.md"
  if [[ ! -f "$PER_TEMPLATE" ]]; then
    log "ERROR: per-session prompt template not found at $PER_TEMPLATE; skipping large entries"
  else
    for f in "${LARGE_FILES[@]}"; do
      source="$(pending_source "$f")"
      cursor_type="$(pending_cursor_type "$f")"
      sid="$(jq -r '.session_id' "$f")"
      proj="$(jq -r '.project_name' "$f")"
      branch="$(jq -r '.git_branch // ""' "$f")"
      tp="$(jq -r '.transcript_path' "$f")"
      cwd="$(jq -r '.session_cwd' "$f")"
      cursor="$(live_cursor_for "$source" "$sid")"

      PROMPT_FILE="$(mktemp /tmp/wiki-synth-large.XXXXXX)"
      export TEMPLATE_FILE="$PER_TEMPLATE" PROMPT_FILE WORK_WIKI DATE_STR TIME_STR
      export PROJECT_NAME="$proj"
      export GIT_BRANCH_LABEL="${branch:-no-branch}"
      export GIT_BRANCH_OR_UNKNOWN="${branch:-unknown}"
      export SESSION_CWD="$cwd"
      export SESSION_ID="$sid"
      export SHORT_ID="${sid:0:8}"
      export SESSION_SOURCE="$source"
      export CURSOR_TYPE="$cursor_type"
      export EXISTING_PROJECTS EXISTING_CONCEPTS
      export TRANSCRIPT_PATH="$tp"
      export LAST_PROCESSED_CURSOR="$cursor"
      export LAST_PROCESSED_UUID="$cursor"

      python3 <<'PYEOF'
import os
from string import Template
with open(os.environ["TEMPLATE_FILE"]) as f:
    tpl = Template(f.read())
rendered = tpl.safe_substitute(
    WORK_WIKI=os.environ.get("WORK_WIKI", ""),
    DATE_STR=os.environ.get("DATE_STR", ""),
    TIME_STR=os.environ.get("TIME_STR", ""),
    PROJECT_NAME=os.environ.get("PROJECT_NAME", ""),
    GIT_BRANCH_LABEL=os.environ.get("GIT_BRANCH_LABEL", ""),
    GIT_BRANCH_OR_UNKNOWN=os.environ.get("GIT_BRANCH_OR_UNKNOWN", ""),
    SESSION_CWD=os.environ.get("SESSION_CWD", ""),
    SESSION_ID=os.environ.get("SESSION_ID", ""),
    SHORT_ID=os.environ.get("SHORT_ID", ""),
    SESSION_SOURCE=os.environ.get("SESSION_SOURCE", "claude"),
    CURSOR_TYPE=os.environ.get("CURSOR_TYPE", "uuid"),
    EXISTING_PROJECTS=os.environ.get("EXISTING_PROJECTS", ""),
    EXISTING_CONCEPTS=os.environ.get("EXISTING_CONCEPTS", ""),
    TRANSCRIPT_PATH=os.environ.get("TRANSCRIPT_PATH", ""),
    LAST_PROCESSED_CURSOR=os.environ.get("LAST_PROCESSED_CURSOR", "none"),
    LAST_PROCESSED_UUID=os.environ.get("LAST_PROCESSED_UUID", "none"),
)
with open(os.environ["PROMPT_FILE"], "w") as f:
    f.write(rendered)
PYEOF

      PROVIDER="$("${RUNNER}" --job session --print-provider)"
      log "Invoking ${PROVIDER} (large ${source}:${sid:0:8}, project=${proj})..."
      EX=0
      "${RUNNER}" \
        --job session \
        --prompt-file "$PROMPT_FILE" \
        --allowed-claude-tools "Bash,Read,Write,Edit,Glob,Grep" \
        --codex-writable-dir "${WORK_WIKI}" \
        --log-label "wiki-synth-large" \
        >> /dev/null 2>&1 || EX=$?
      log "${PROVIDER} (large ${source}:${sid:0:8}) exited: $EX"
      rm -f "$PROMPT_FILE"

      if [[ "$EX" -eq 0 ]]; then
        L="$(latest_cursor "$source" "$tp")"
        if [[ -n "$L" ]]; then
          echo "$L" > "$(state_file_for "$source" "$sid")"
          log "  cursor advanced ${source}:${sid:0:8} → $L"
        fi
        rm -f "$f"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        record_success_project "$proj"
      else
        log "WARN: large run for ${source}:${sid:0:8} failed; leaving pending file in place"
      fi
    done
  fi
fi

# --- Auto-compress over-budget bullets on synth-touched pages ---
# Invokes the configured headless provider per offending bullet to rewrite it in place. Scoped to
# pages the synth modified this run; rewrites fold into the same commit.
# Failures are skipped (script keeps the original); the advisory detector
# below logs any residuals.
while IFS= read -r _ac_line; do
  log "$_ac_line"
done < <(bash "${WORK_WIKI}/.system/scripts/auto-compress-touched.sh" 2>/dev/null) || true

# --- Post-synth advisory detectors (never blocks the commit) ---
# Logs warnings for over-budget Recent-activity bullets on synth-touched
# pages and for synthesis pages rotting behind linked entities. Pure-Python,
# no LLM call. See .system/scripts/post-synth-detect.sh.
while IFS= read -r _detect_line; do
  log "$_detect_line"
done < <(bash "${WORK_WIKI}/.system/scripts/post-synth-detect.sh" 2>/dev/null) || true

# --- Commit (with concurrent-safe lock) ---
if [[ "$SUCCESS_COUNT" -eq 0 ]]; then
  log "No successful synth runs; nothing to commit."
  log "=== Done ==="
  exit 0
fi

GIT_LOCK="${WORK_WIKI}/.git-commit-lock"
GIT_LOCK_ACQUIRED=false
for i in $(seq 1 30); do
  if mkdir "$GIT_LOCK" 2>/dev/null; then
    GIT_LOCK_ACQUIRED=true
    break
  fi
  sleep 1
done

if "$GIT_LOCK_ACQUIRED"; then
  git -C "$WORK_WIKI" add -A 2>/dev/null || true
  PROJ_LIST="$(IFS=', '; echo "${SUCCESS_PROJECTS[*]:-}")"
  COMMIT_MSG="wiki: synthesized ${SUCCESS_COUNT} session(s) on ${DATE_STR} - ${PROJ_LIST}"
  if git -C "$WORK_WIKI" commit -m "$COMMIT_MSG" 2>/dev/null; then
    log "Committed: $COMMIT_MSG"
    if [[ "$AUTO_PUSH" == "1" || "$AUTO_PUSH" == "true" ]]; then
      if git -C "$WORK_WIKI" push origin main 2>>"$LOG_FILE"; then
        log "Pushed to origin/main"
      else
        log "WARN: push to origin/main failed; commit stays local"
      fi
    fi
  else
    log "Nothing to commit (no wiki-worthy content surfaced)"
  fi
  rmdir "$GIT_LOCK" 2>/dev/null || true
else
  log "WARN: could not acquire git lock after 30s; files written but not committed"
fi

log "=== Done (success=${SUCCESS_COUNT}, projects=${SUCCESS_PROJECTS[*]:-}) ==="
