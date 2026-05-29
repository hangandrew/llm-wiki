#!/usr/bin/env bash
# Pass 1: extract per-transcript metadata into a JSONL index.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_WIKI="$(cd "${SCRIPT_DIR}/../.." && pwd)"

OUT_FILE="${WORK_WIKI}/.system/state/backfill-index.jsonl"
export OUT_FILE

python3 "${SCRIPT_DIR}/backfill-extract.py"
echo "Index: ${OUT_FILE}"
echo "  total: $(wc -l < "${OUT_FILE}" | tr -d ' ')"
echo "  passes triage: $(jq -s 'map(select(.passes_triage)) | length' "${OUT_FILE}")"
