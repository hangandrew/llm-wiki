#!/usr/bin/env bash
# Pass 2: invoke the configured headless provider to synthesize the wiki from the metadata index.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_WIKI="$(cd "${SCRIPT_DIR}/../.." && pwd)"

INDEX_FILE="${WORK_WIKI}/.system/state/backfill-index.jsonl"
TEMPLATE_FILE="${WORK_WIKI}/.system/prompts/wiki-initial-build.md"
RUNNER="${WORK_WIKI}/.system/scripts/headless-agent-run.sh"

[[ -f "${INDEX_FILE}" ]] || {
  echo "ERROR: index not found at ${INDEX_FILE}; run backfill-extract.sh first" >&2
  exit 1
}
[[ -f "${TEMPLATE_FILE}" ]] || {
  echo "ERROR: prompt not found at ${TEMPLATE_FILE}" >&2
  exit 1
}

DATE_STR="$(date '+%Y-%m-%d')"
TOTAL="$(wc -l < "${INDEX_FILE}" | tr -d ' ')"
PASSING="$(jq -s 'map(select(.passes_triage)) | length' "${INDEX_FILE}")"

PROMPT_FILE="/tmp/wiki-initial-build-prompt.txt"

export WORK_WIKI INDEX_FILE DATE_STR TOTAL PASSING TEMPLATE_FILE PROMPT_FILE

python3 <<'PYEOF'
import os
from string import Template

with open(os.environ["TEMPLATE_FILE"]) as f:
    tpl = Template(f.read())

rendered = tpl.safe_substitute(
    WORK_WIKI=os.environ["WORK_WIKI"],
    INDEX_FILE=os.environ["INDEX_FILE"],
    DATE_STR=os.environ["DATE_STR"],
    TOTAL=os.environ["TOTAL"],
    PASSING=os.environ["PASSING"],
)

with open(os.environ["PROMPT_FILE"], "w") as f:
    f.write(rendered)
PYEOF

PROVIDER="$("${RUNNER}" --job backfill --print-provider)"
echo "Invoking ${PROVIDER} to synthesize wiki from ${PASSING} passing transcripts (of ${TOTAL} total)..."
echo "  index:  ${INDEX_FILE}"
echo "  prompt: ${PROMPT_FILE}"
echo "  log:    ${HOME}/.claude/logs/wiki-backfill.log"

mkdir -p "${HOME}/.claude/logs"
"${RUNNER}" \
  --job backfill \
  --prompt-file "${PROMPT_FILE}" \
  --allowed-claude-tools "Bash,Read,Write,Edit,Glob,Grep" \
  --codex-writable-dir "${WORK_WIKI}" \
  --log-label "wiki-backfill" \
  2>&1 | tee -a "${HOME}/.claude/logs/wiki-backfill.log"

rm -f "${PROMPT_FILE}"
echo "Synthesis done."
