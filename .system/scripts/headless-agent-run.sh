#!/usr/bin/env bash
# Shared headless LLM runner for wiki synthesis jobs.
#
# Provider resolution order:
#   1. WORK_WIKI_<JOB>_SYNTH_PROVIDER
#   2. WORK_WIKI_SYNTH_PROVIDER
#   3. claude
#
# Supported providers:
#   claude: claude -p "$prompt" --allowedTools "$tools"
#   codex:  codex -a never exec -C "$WORK_WIKI" -s workspace-write -
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_WIKI="${WORK_WIKI:-${WORK_WIKI_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}}"

JOB=""
PROMPT_FILE=""
READ_STDIN=0
CLAUDE_TOOLS=""
LOG_LABEL=""
PRINT_PROVIDER=0
CODEX_READABLE_DIRS=()
CODEX_WRITABLE_DIRS=()

usage() {
  cat <<'EOF'
Usage: headless-agent-run.sh --job NAME (--prompt-file PATH | --stdin) [options]

Options:
  --allowed-claude-tools TOOLS   Comma-separated Claude tool allowlist.
  --codex-readable-dir DIR       Additional directory passed to Codex with --add-dir.
  --codex-writable-dir DIR       Additional directory passed to Codex with --add-dir.
  --log-label LABEL              Human label for errors/logging.
  --print-provider               Print resolved provider and exit.
EOF
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --job) JOB="${2:-}"; shift 2 ;;
    --prompt-file) PROMPT_FILE="${2:-}"; shift 2 ;;
    --stdin) READ_STDIN=1; shift ;;
    --allowed-claude-tools) CLAUDE_TOOLS="${2:-}"; shift 2 ;;
    --codex-readable-dir) CODEX_READABLE_DIRS+=("${2:-}"); shift 2 ;;
    --codex-writable-dir) CODEX_WRITABLE_DIRS+=("${2:-}"); shift 2 ;;
    --log-label) LOG_LABEL="${2:-}"; shift 2 ;;
    --print-provider) PRINT_PROVIDER=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "${JOB}" ]]; then
  echo "ERROR: --job is required" >&2
  exit 2
fi
if [[ -z "${PROMPT_FILE}" && "${READ_STDIN}" -eq 0 && "${PRINT_PROVIDER}" -eq 0 ]]; then
  echo "ERROR: provide --prompt-file or --stdin" >&2
  exit 2
fi
if [[ -n "${PROMPT_FILE}" && "${READ_STDIN}" -eq 1 ]]; then
  echo "ERROR: use only one of --prompt-file or --stdin" >&2
  exit 2
fi

job_key="$(printf '%s' "${JOB}" | tr '[:lower:]-' '[:upper:]_')"
job_var="WORK_WIKI_${job_key}_SYNTH_PROVIDER"
provider="${!job_var:-${WORK_WIKI_SYNTH_PROVIDER:-claude}}"
provider="$(printf '%s' "${provider}" | tr '[:upper:]' '[:lower:]')"
label="${LOG_LABEL:-${JOB}}"

case "${provider}" in
  claude|codex) ;;
  *)
    echo "ERROR: unknown synth provider '${provider}' for ${label}; expected claude or codex" >&2
    exit 2
    ;;
esac

if [[ "${PRINT_PROVIDER}" -eq 1 ]]; then
  echo "${provider}"
  exit 0
fi

if [[ "${provider}" == "claude" ]]; then
  command -v claude >/dev/null 2>&1 || { echo "ERROR: claude CLI not found on PATH" >&2; exit 127; }
  if [[ -n "${PROMPT_FILE}" ]]; then
    prompt="$(cat "${PROMPT_FILE}")"
  else
    prompt="$(cat)"
  fi
  if [[ -n "${CLAUDE_TOOLS}" ]]; then
    claude -p "${prompt}" --allowedTools "${CLAUDE_TOOLS}"
  else
    claude -p "${prompt}"
  fi
elif [[ "${provider}" == "codex" ]]; then
  command -v codex >/dev/null 2>&1 || { echo "ERROR: codex CLI not found on PATH" >&2; exit 127; }
  codex_args=(-a never exec -C "${WORK_WIKI}" -s workspace-write)
  if [[ "${#CODEX_READABLE_DIRS[@]}" -gt 0 ]]; then
    for dir in "${CODEX_READABLE_DIRS[@]}"; do
      [[ -n "${dir}" ]] && codex_args+=(--add-dir "${dir}")
    done
  fi
  if [[ "${#CODEX_WRITABLE_DIRS[@]}" -gt 0 ]]; then
    for dir in "${CODEX_WRITABLE_DIRS[@]}"; do
      [[ -n "${dir}" ]] && codex_args+=(--add-dir "${dir}")
    done
  fi
  if [[ -n "${PROMPT_FILE}" ]]; then
    codex "${codex_args[@]}" - < "${PROMPT_FILE}"
  else
    codex "${codex_args[@]}" -
  fi
fi
