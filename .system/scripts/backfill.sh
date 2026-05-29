#!/usr/bin/env bash
# One-shot orchestrator for the initial wiki backfill.
# Pass 1: extract metadata from every Claude transcript in ~/.claude/projects/.
# Optional: enqueue historical Codex sessions through the mixed-source queue.
# Pass 2: invoke the configured headless provider to synthesize the wiki from the index / queue.
# Then commits any wiki changes.

set -euo pipefail

INCLUDE_CODEX=0
for arg in "$@"; do
  case "$arg" in
    --include-codex) INCLUDE_CODEX=1 ;;
    -h|--help)
      cat <<'EOF'
Usage: backfill.sh [--include-codex]
  --include-codex  Also index historical Codex threads and enqueue them for the shared synthesizer.
EOF
      exit 0
      ;;
    *)
      echo "Unknown argument: ${arg}" >&2
      exit 2
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_WIKI="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "=== Pass 1: extract ==="
bash "${SCRIPT_DIR}/backfill-extract.sh"

if [[ "${INCLUDE_CODEX}" -eq 1 ]]; then
  echo
  echo "=== Optional: Codex historical enqueue ==="
  python3 "${SCRIPT_DIR}/codex-extract.py" \
    --work-wiki "${WORK_WIKI}" \
    --include-active \
    --enqueue \
    --index "${WORK_WIKI}/.system/state/codex-index.jsonl"
fi

echo
echo "=== Pass 2: synthesize ==="
bash "${SCRIPT_DIR}/backfill-synthesize.sh"
if [[ "${INCLUDE_CODEX}" -eq 1 ]]; then
  bash "${WORK_WIKI}/.system/hooks/wiki-synthesizer.sh" --force
fi

echo
echo "=== Commit ==="
cd "${WORK_WIKI}"
git add -A
if git commit -m "wiki: initial backfill from agent sessions" 2>/dev/null; then
  echo "Committed."
else
  echo "(no changes to commit)"
fi
