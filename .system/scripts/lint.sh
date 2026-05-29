#!/usr/bin/env bash
# Run a lint pass over the wiki. Output goes to wiki/syntheses/lint-<date>.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_WIKI="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TEMPLATE_FILE="${WORK_WIKI}/.system/prompts/wiki-lint.md"
RUNNER="${WORK_WIKI}/.system/scripts/headless-agent-run.sh"
DATE_STR="$(date '+%Y-%m-%d')"
PROMPT_FILE="/tmp/wiki-lint-prompt.txt"

[[ -f "${TEMPLATE_FILE}" ]] || { echo "ERROR: prompt not found at ${TEMPLATE_FILE}" >&2; exit 1; }

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

echo "Linting wiki at ${WORK_WIKI}..."
"${RUNNER}" \
  --job lint \
  --prompt-file "${PROMPT_FILE}" \
  --allowed-claude-tools "Bash,Read,Write,Glob,Grep" \
  --codex-writable-dir "${WORK_WIKI}" \
  --log-label "wiki-lint"
rm -f "${PROMPT_FILE}"
echo "Lint report: ${WORK_WIKI}/wiki/syntheses/lint-${DATE_STR}.md"
