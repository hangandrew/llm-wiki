#!/usr/bin/env bash
# PR-state poller for the worklog. Runs every ~10 minutes (launchd).
#
# Hybrid: deterministic by default, LLM only on a structural event.
#   1. Discover the user's open + recently-closed PRs via `gh search prs`.
#   2. Deterministically refresh the `## PR state` block on tracked live items
#      (no LLM). Commit only when something changed.
#   3. Fire the headless agent ONLY when there are new PRs to enroll or
#      merged/closed PRs to archive — the structural events. Routine
#      "CI went green / got an approval" updates stay LLM-free.
#
# Serializes against the synthesizer via the shared lock so the two never
# run git concurrently. Always exits 0-ish; never blocks.

set -euo pipefail

WORK_WIKI="${WORK_WIKI_DIR:-${WORK_TRACKER_DIR:-${HOME}/work-wiki}}"
LIVE_DIR="${WORK_WIKI}/worklog/live"
ARCHIVE_DIR="${WORK_WIKI}/worklog/archive"
BOARD="${WORK_WIKI}/worklog/board.md"
LOCK_DIR="${WORK_WIKI}/.system/state/synthesizer.lock"   # shared with the synthesizer
GIT_LOCK="${WORK_WIKI}/.git-commit-lock"                  # shared commit lock
RUNNER="${WORK_WIKI}/.system/scripts/headless-agent-run.sh"
PROMPT_TEMPLATE="${WORK_WIKI}/.system/prompts/worklog-pr-sync.md"
LOG_DIR="${HOME}/.claude/logs"
LOG_FILE="${LOG_DIR}/wiki-pr-sync.log"

mkdir -p "${LOG_DIR}"
ts() { date '+%Y-%m-%dT%H:%M:%S'; }
log() { echo "[$(ts)] [pr-sync] $*" >> "${LOG_FILE}"; }

FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    -h|--help) echo "Usage: pr-state-sync.sh [--force]"; exit 0 ;;
  esac
done

# Worklog must exist; otherwise nothing to sync.
if [[ ! -d "${LIVE_DIR}" ]]; then
  log "no worklog/live dir at ${LIVE_DIR}; nothing to do"
  exit 0
fi

# gh must be present and authenticated.
if ! command -v gh >/dev/null 2>&1; then
  log "gh CLI not on PATH; skipping"
  exit 0
fi
if ! gh auth status >/dev/null 2>&1; then
  log "gh not authenticated; skipping"
  exit 0
fi

# --- Shared lock: never write while the synthesizer is running ---
mkdir -p "$(dirname "$LOCK_DIR")"
if [[ "$FORCE" -eq 1 ]]; then
  rmdir "$LOCK_DIR" 2>/dev/null || true
fi
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  log "SKIP: synthesizer/poller lock held ($LOCK_DIR)"
  exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM

log "=== Starting PR sync ==="

DATE_STR="$(date '+%Y-%m-%d')"
TMP_OPEN="$(mktemp /tmp/pr-sync-open.XXXXXX)"
TMP_CLOSED="$(mktemp /tmp/pr-sync-closed.XXXXXX)"
TMP_DETAILS="$(mktemp /tmp/pr-sync-details.XXXXXX)"
TMP_DELTAS="$(mktemp /tmp/pr-sync-deltas.XXXXXX)"
cleanup_tmp() { rm -f "$TMP_OPEN" "$TMP_CLOSED" "$TMP_DETAILS" "$TMP_DELTAS"; }
trap 'cleanup_tmp; rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM

# --- Discover PRs authored by the current user ---
if ! gh search prs --author=@me --state=open --limit 100 \
      --json number,title,url,repository,updatedAt > "$TMP_OPEN" 2>>"$LOG_FILE"; then
  log "WARN: gh search (open) failed; aborting this run"
  exit 0
fi
# Recently closed/merged, to detect archival of tracked items.
gh search prs --author=@me --state=closed --limit 50 \
  --json number,title,url,repository,state,updatedAt > "$TMP_CLOSED" 2>>"$LOG_FILE" || echo "[]" > "$TMP_CLOSED"

OPEN_COUNT="$(jq 'length' "$TMP_OPEN" 2>/dev/null || echo 0)"
log "open PRs (mine): ${OPEN_COUNT}"

# --- Fetch full detail for each open PR (CI, review, mergeable, branch) ---
: > "$TMP_DETAILS"
while IFS=$'\t' read -r num repo; do
  [[ -n "$num" && -n "$repo" ]] || continue
  if detail="$(gh pr view "$num" --repo "$repo" \
        --json number,title,url,headRefName,isDraft,reviewDecision,statusCheckRollup,mergeable,state \
        2>>"$LOG_FILE")"; then
    # annotate with repo for downstream use
    printf '%s\n' "$(jq -c --arg repo "$repo" '. + {repository:$repo}' <<<"$detail")" >> "$TMP_DETAILS"
  else
    log "WARN: gh pr view ${repo}#${num} failed; skipping detail"
  fi
done < <(jq -r '.[] | [(.number|tostring), .repository.nameWithOwner] | @tsv' "$TMP_OPEN")

# --- Deterministic refresh + delta computation (no LLM) ---
# Reads tracked live items, updates their ## PR state blocks in place, and
# emits {changed_files, new_prs, closed_tracked} as JSON to TMP_DELTAS.
LIVE_DIR="$LIVE_DIR" DETAILS_FILE="$TMP_DETAILS" CLOSED_FILE="$TMP_CLOSED" \
DATE_STR="$DATE_STR" DELTAS_OUT="$TMP_DELTAS" python3 <<'PYEOF'
import json, os, re, glob

live_dir = os.environ["LIVE_DIR"]
date_str = os.environ["DATE_STR"]

def load_jsonl(path):
    out = []
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line:
                    out.append(json.loads(line))
    except FileNotFoundError:
        pass
    return out

def load_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return default

details = load_jsonl(os.environ["DETAILS_FILE"])           # open PR detail records
closed = load_json(os.environ["CLOSED_FILE"], [])           # recently closed/merged

details_by_num = {int(d["number"]): d for d in details if d.get("number") is not None}
closed_by_num = {int(c["number"]): c for c in closed if c.get("number") is not None}

# --- Build tracked index from live items: pr_number -> {file, slug} ---
KEY_RE = re.compile(r"PR#(\d+)")
def frontmatter(text):
    if not text.startswith("---"):
        return {}
    end = text.find("\n---", 3)
    if end == -1:
        return {}
    fm = {}
    for line in text[3:end].splitlines():
        m = re.match(r"^([A-Za-z_]+):\s*(.*)$", line)
        if m:
            fm[m.group(1)] = m.group(2).strip()
    return fm

tracked = {}   # pr_number -> {"file":..., "slug":...}
for path in sorted(glob.glob(os.path.join(live_dir, "*.md"))):
    with open(path) as f:
        text = f.read()
    fm = frontmatter(text)
    keys = fm.get("keys", "")
    slug = fm.get("slug") or os.path.splitext(os.path.basename(path))[0]
    for m in KEY_RE.finditer(keys):
        tracked[int(m.group(1))] = {"file": path, "slug": slug}

def ci_summary(rollup):
    if not rollup:
        return "no checks"
    states = []
    for c in rollup:
        s = (c.get("conclusion") or c.get("state") or c.get("status") or "").upper()
        states.append(s)
    if any(s in ("FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED") for s in states):
        return "failing"
    if any(s in ("PENDING", "IN_PROGRESS", "QUEUED", "EXPECTED", "WAITING", "") for s in states):
        return "pending"
    if states and all(s in ("SUCCESS", "NEUTRAL", "SKIPPED") for s in states):
        return "passing"
    return "mixed"

def review_summary(decision):
    return {
        "APPROVED": "approved",
        "CHANGES_REQUESTED": "changes-requested",
        "REVIEW_REQUIRED": "review-required",
        "": "no review",
        None: "no review",
    }.get(decision, (decision or "no review").lower())

def state_line(d):
    draft = " · draft" if d.get("isDraft") else ""
    ci = ci_summary(d.get("statusCheckRollup"))
    rev = review_summary(d.get("reviewDecision"))
    merge = (d.get("mergeable") or "UNKNOWN").lower()
    st = (d.get("state") or "OPEN").lower()
    return f"{st}{draft} · CI: {ci} · review: {rev} · mergeable: {merge} · synced {date_str}"

MARKER = "<!-- managed by pr-state-sync.sh — do not hand-edit -->"

def upsert_pr_state(text, line):
    """Canonically (re)write the '## PR state' section. Idempotent: strip any
    existing section, then re-insert before '## Links' (or append), and
    normalize blank lines. Returns (new_text, changed:bool)."""
    block = f"## PR state\n{MARKER}\n{line}"
    # Remove any existing PR state section (plus the blank lines preceding it).
    stripped = re.sub(r"\n+## PR state[ \t]*\n.*?(?=\n## |\Z)", "\n", text,
                      flags=re.DOTALL)
    if "\n## Links" in stripped:
        idx = stripped.find("\n## Links")
        new = (stripped[:idx].rstrip("\n") + "\n\n" + block + "\n\n"
               + stripped[idx:].lstrip("\n"))
    else:
        new = stripped.rstrip("\n") + "\n\n" + block + "\n"
    new = re.sub(r"\n{3,}", "\n\n", new).rstrip("\n") + "\n"
    return new, (new != text)

changed_files = []
# Deterministic refresh for tracked PRs that are currently open.
for num, info in tracked.items():
    d = details_by_num.get(num)
    if not d:
        continue
    with open(info["file"]) as f:
        text = f.read()
    new_text, changed = upsert_pr_state(text, state_line(d))
    if changed:
        with open(info["file"], "w") as f:
            f.write(new_text)
        changed_files.append(info["file"])

# Deltas requiring the LLM.
new_prs = []
for d in details:
    num = int(d["number"])
    if num not in tracked:
        new_prs.append({
            "number": num,
            "title": d.get("title", ""),
            "url": d.get("url", ""),
            "branch": d.get("headRefName", ""),
            "repository": d.get("repository", ""),
            "isDraft": bool(d.get("isDraft")),
        })

closed_tracked = []
for num, info in tracked.items():
    if num in details_by_num:
        continue  # still open
    c = closed_by_num.get(num)
    if c:
        closed_tracked.append({
            "number": num,
            "slug": info["slug"],
            "file": info["file"],
            "state": c.get("state", "CLOSED"),
            "url": c.get("url", ""),
            "title": c.get("title", ""),
        })

with open(os.environ["DELTAS_OUT"], "w") as f:
    json.dump({
        "changed_files": changed_files,
        "new_prs": new_prs,
        "closed_tracked": closed_tracked,
    }, f)
PYEOF

CHANGED_COUNT="$(jq '.changed_files | length' "$TMP_DELTAS" 2>/dev/null || echo 0)"
NEW_COUNT="$(jq '.new_prs | length' "$TMP_DELTAS" 2>/dev/null || echo 0)"
CLOSED_COUNT="$(jq '.closed_tracked | length' "$TMP_DELTAS" 2>/dev/null || echo 0)"
log "deterministic: ${CHANGED_COUNT} state update(s); deltas: ${NEW_COUNT} new, ${CLOSED_COUNT} merged/closed"

# --- LLM pass: ONLY when there is a structural event ---
LLM_RAN=0
if [[ "${NEW_COUNT}" -gt 0 || "${CLOSED_COUNT}" -gt 0 ]]; then
  NEW_PRS_BLOCK="$(jq -r '
    if (.new_prs | length) == 0 then "_(none)_"
    else (.new_prs[] | "- PR #\(.number) [\(.repository)] \(.title)\n  - URL: \(.url)\n  - Branch: \(.branch)\(if .isDraft then " (draft)" else "" end)") end
  ' "$TMP_DELTAS")"
  CLOSED_BLOCK="$(jq -r '
    if (.closed_tracked | length) == 0 then "_(none)_"
    else (.closed_tracked[] | "- \(.slug) — PR #\(.number) is now \(.state) (\(.url))\n  - file: worklog/live/\(.file | split("/") | last)") end
  ' "$TMP_DELTAS")"

  PROMPT_FILE="$(mktemp /tmp/pr-sync-prompt.XXXXXX)"
  if [[ -f "${PROMPT_TEMPLATE}" ]]; then
    TEMPLATE_FILE="${PROMPT_TEMPLATE}" PROMPT_OUT="${PROMPT_FILE}" WORK_WIKI="${WORK_WIKI}" \
    DATE_STR="${DATE_STR}" NEW_PRS_BLOCK="${NEW_PRS_BLOCK}" CLOSED_BLOCK="${CLOSED_BLOCK}" \
    python3 <<'PYEOF'
import os
from string import Template
with open(os.environ["TEMPLATE_FILE"]) as f:
    tpl = Template(f.read())
rendered = tpl.safe_substitute(
    WORK_WIKI=os.environ.get("WORK_WIKI", ""),
    DATE_STR=os.environ.get("DATE_STR", ""),
    NEW_PRS_BLOCK=os.environ.get("NEW_PRS_BLOCK", ""),
    CLOSED_BLOCK=os.environ.get("CLOSED_BLOCK", ""),
)
with open(os.environ["PROMPT_OUT"], "w") as f:
    f.write(rendered)
PYEOF
    PROVIDER="$("${RUNNER}" --job worklog-pr-sync --print-provider 2>/dev/null || echo claude)"
    log "Invoking ${PROVIDER} (structural events: ${NEW_COUNT} new, ${CLOSED_COUNT} closed)..."
    EX=0
    "${RUNNER}" \
      --job worklog-pr-sync \
      --prompt-file "${PROMPT_FILE}" \
      --allowed-claude-tools "Bash,Read,Write,Edit,Glob,Grep" \
      --codex-writable-dir "${WORK_WIKI}" \
      --log-label "worklog-pr-sync" \
      >> /dev/null 2>&1 || EX=$?
    log "${PROVIDER} exited: ${EX}"
    [[ "${EX}" -eq 0 ]] && LLM_RAN=1 || log "WARN: LLM pass failed; deterministic updates still commit"
  else
    log "WARN: prompt template missing at ${PROMPT_TEMPLATE}; skipping LLM pass"
  fi
  rm -f "${PROMPT_FILE}"
fi

# --- Commit worklog changes (shared git lock), only if something changed ---
if [[ "${CHANGED_COUNT}" -eq 0 && "${LLM_RAN}" -eq 0 ]]; then
  log "no changes; nothing to commit"
  log "=== Done ==="
  exit 0
fi

# Stage only worklog/ and bail if the working tree there is actually clean.
if git -C "${WORK_WIKI}" diff --quiet -- worklog 2>/dev/null && \
   git -C "${WORK_WIKI}" diff --cached --quiet -- worklog 2>/dev/null && \
   [[ -z "$(git -C "${WORK_WIKI}" ls-files --others --exclude-standard -- worklog)" ]]; then
  log "worklog tree clean after run; nothing to commit"
  log "=== Done ==="
  exit 0
fi

GIT_LOCK_ACQUIRED=false
for i in $(seq 1 30); do
  if mkdir "$GIT_LOCK" 2>/dev/null; then GIT_LOCK_ACQUIRED=true; break; fi
  sleep 1
done

if "$GIT_LOCK_ACQUIRED"; then
  git -C "${WORK_WIKI}" add -A -- worklog 2>/dev/null || true
  if [[ "${NEW_COUNT}" -gt 0 || "${CLOSED_COUNT}" -gt 0 ]]; then
    MSG="worklog: PR sync — ${NEW_COUNT} new, ${CLOSED_COUNT} archived, ${CHANGED_COUNT} state update(s) on ${DATE_STR}"
  else
    MSG="worklog: PR state sync ${DATE_STR} (${CHANGED_COUNT} update(s))"
  fi
  if git -C "${WORK_WIKI}" commit -m "${MSG}" 2>/dev/null; then
    log "Committed: ${MSG}"
    if [[ "${WORK_WIKI_AUTO_PUSH:-0}" == "1" || "${WORK_WIKI_AUTO_PUSH:-0}" == "true" ]]; then
      git -C "${WORK_WIKI}" push origin main 2>>"$LOG_FILE" && log "Pushed to origin/main" || log "WARN: push failed; commit stays local"
    fi
  else
    log "Nothing to commit"
  fi
  rmdir "$GIT_LOCK" 2>/dev/null || true
else
  log "WARN: could not acquire git lock after 30s; changes written but not committed"
fi

log "=== Done ==="
