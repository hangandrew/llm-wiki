#!/usr/bin/env bash
# Idempotent installer — safe to run multiple times or on a new machine.
# Prints the actions it will take with all paths resolved, asks for confirmation,
# then executes. Pass --yes to skip the prompt.
#
# Also migrates from the legacy "work-tracker" install:
#   - old hook symlink ~/.claude/hooks/knowledge-session-end.sh → removed
#   - old SessionEnd entry in settings.json → rewritten to the new path
#   - old <!-- work-tracker --> block in ~/.claude/CLAUDE.md → replaced with <!-- work-wiki -->
#   - old WORK_TRACKER_AUTO_PUSH env → migrated to WORK_WIKI_AUTO_PUSH
#
# Installs agent context for both Claude Code (~/.claude/CLAUDE.md) and Codex
# (~/.codex/config.toml developer_instructions).

set -euo pipefail

ASSUME_YES=0
AUTO_PUSH_CHOICE=""        # "1" = enable, "0" = skip, "" = ask interactively
SYNTH_PROVIDER_CHOICE=""   # "claude" or "codex"; "" = ask interactively / default
DAILY_CHOICE="1"           # "1" = install plist, "0" = skip
SLACK_DAILY_CHOICE="1"     # "1" = install plist, "0" = skip
GRANOLA_DAILY_CHOICE="1"   # "1" = install plist, "0" = skip
REFACTOR_DAILY_CHOICE="1"  # "1" = install plist, "0" = skip
CODEX_INGEST_CHOICE="1"    # "1" = install plist, "0" = skip
EXPECT_SYNTH_PROVIDER=0
for arg in "$@"; do
  if [[ "${EXPECT_SYNTH_PROVIDER}" -eq 1 ]]; then
    SYNTH_PROVIDER_CHOICE="${arg}"
    EXPECT_SYNTH_PROVIDER=0
    continue
  fi
  case "${arg}" in
    -y|--yes) ASSUME_YES=1 ;;
    --auto-push) AUTO_PUSH_CHOICE=1 ;;
    --no-auto-push) AUTO_PUSH_CHOICE=0 ;;
    --synth-provider) EXPECT_SYNTH_PROVIDER=1 ;;
    --synth-provider=*)
      SYNTH_PROVIDER_CHOICE="${arg#*=}"
      ;;
    --enable-daily) DAILY_CHOICE=1 ;;
    --no-enable-daily) DAILY_CHOICE=0 ;;
    --enable-slack-daily) SLACK_DAILY_CHOICE=1 ;;
    --no-enable-slack-daily) SLACK_DAILY_CHOICE=0 ;;
    --enable-granola-daily) GRANOLA_DAILY_CHOICE=1 ;;
    --no-enable-granola-daily) GRANOLA_DAILY_CHOICE=0 ;;
    --enable-refactor-daily|--enable-refactor-weekly) REFACTOR_DAILY_CHOICE=1 ;;
    --no-enable-refactor-daily|--no-enable-refactor-weekly) REFACTOR_DAILY_CHOICE=0 ;;
    --enable-codex-ingest) CODEX_INGEST_CHOICE=1 ;;
    --no-enable-codex-ingest) CODEX_INGEST_CHOICE=0 ;;
    -h|--help)
      cat <<'EOF'
Usage: install.sh [-y|--yes] [--auto-push|--no-auto-push]
                  [--synth-provider claude|codex]
                  [--enable-daily|--no-enable-daily]
                  [--enable-slack-daily|--no-enable-slack-daily]
                  [--enable-granola-daily|--no-enable-granola-daily]
                  [--enable-refactor-daily|--no-enable-refactor-daily]
                  [--enable-codex-ingest|--no-enable-codex-ingest]
  -y, --yes                       Skip the confirmation prompt (for unattended runs)
      --auto-push                 Set WORK_WIKI_AUTO_PUSH=1 in ~/.claude/settings.json env block
      --no-auto-push              Skip the auto-push prompt and leave settings.json env alone
      --synth-provider PROVIDER   Set WORK_WIKI_SYNTH_PROVIDER to claude or codex
      --enable-daily              Install the daily 8pm synthesizer launchd plist (default)
      --no-enable-daily           Skip installing the synthesizer daily plist
      --enable-slack-daily        Install the daily 8pm Slack-ingest launchd plist (default)
      --no-enable-slack-daily     Skip installing the Slack-ingest daily plist
      --enable-granola-daily      Install the daily 8pm Granola-ingest launchd plist (default)
      --no-enable-granola-daily   Skip installing the Granola-ingest daily plist
      --enable-refactor-daily     Install the daily 8:30pm structural-review launchd plist (default)
      --no-enable-refactor-daily  Skip installing the refactor-review daily plist
                                  (legacy --enable-refactor-weekly is still accepted)
      --enable-codex-ingest       Install the every-15-minutes Codex ingest launchd plist (default)
      --no-enable-codex-ingest    Skip installing the Codex ingest launchd plist
  -h, --help                      Show this help
EOF
      exit 0
      ;;
    *)
      echo "Unknown argument: ${arg}" >&2
      exit 2
      ;;
  esac
done
if [[ "${EXPECT_SYNTH_PROVIDER}" -eq 1 ]]; then
  echo "ERROR: --synth-provider requires claude or codex" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_WIKI="$(dirname "${SCRIPT_DIR}")"
HOOKS_DIR="${HOME}/.claude/hooks"
SETTINGS="${HOME}/.claude/settings.json"
LOG_DIR="${HOME}/.claude/logs"
CLAUDE_MD="${HOME}/.claude/CLAUDE.md"
CODEX_CONFIG="${HOME}/.codex/config.toml"

normalize_provider() {
  local provider
  provider="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "${provider}" in
    claude|codex) echo "${provider}" ;;
    *)
      echo "ERROR: invalid synth provider '${1}'. Expected claude or codex." >&2
      exit 2
      ;;
  esac
}

settings_synth_provider() {
  if [[ -f "${SETTINGS}" ]] && command -v jq >/dev/null 2>&1; then
    jq -r '.env.WORK_WIKI_SYNTH_PROVIDER // empty' "${SETTINGS}" 2>/dev/null || true
  fi
}

DEFAULT_SYNTH_PROVIDER="${WORK_WIKI_SYNTH_PROVIDER:-$(settings_synth_provider)}"
DEFAULT_SYNTH_PROVIDER="${DEFAULT_SYNTH_PROVIDER:-claude}"
DEFAULT_SYNTH_PROVIDER="$(normalize_provider "${DEFAULT_SYNTH_PROVIDER}")"

if [[ -n "${SYNTH_PROVIDER_CHOICE}" ]]; then
  SYNTH_PROVIDER_CHOICE="$(normalize_provider "${SYNTH_PROVIDER_CHOICE}")"
elif [[ "${ASSUME_YES}" -eq 1 ]]; then
  SYNTH_PROVIDER_CHOICE="${DEFAULT_SYNTH_PROVIDER}"
elif [[ -t 0 ]]; then
  echo "Headless synthesis provider:"
  echo "  claude  default, current behavior"
  echo "  codex   use Codex CLI for wiki-writing synth jobs"
  read -r -p "Choose provider [${DEFAULT_SYNTH_PROVIDER}]: " ans
  SYNTH_PROVIDER_CHOICE="$(normalize_provider "${ans:-${DEFAULT_SYNTH_PROVIDER}}")"
fi

SYNTH_PROVIDER="${SYNTH_PROVIDER_CHOICE:-${DEFAULT_SYNTH_PROVIDER}}"
export WORK_WIKI_SYNTH_PROVIDER="${SYNTH_PROVIDER}"

# --- Preflight: fail fast if required tools or git identity are missing ---
preflight() {
  local platform missing=()
  platform="$(uname -s)"
  local synth_provider job_provider needs_codex_cli=0
  synth_provider="${SYNTH_PROVIDER}"
  [[ "${synth_provider}" == "codex" ]] && needs_codex_cli=1
  for job_provider in \
    "${WORK_WIKI_SESSION_SYNTH_PROVIDER:-}" \
    "${WORK_WIKI_BACKFILL_SYNTH_PROVIDER:-}" \
    "${WORK_WIKI_SLACK_SYNTH_PROVIDER:-}" \
    "${WORK_WIKI_GRANOLA_SYNTH_PROVIDER:-}" \
    "${WORK_WIKI_LINT_SYNTH_PROVIDER:-}" \
    "${WORK_WIKI_REFACTOR_SYNTH_PROVIDER:-}" \
    "${WORK_WIKI_COMPRESS_SYNTH_PROVIDER:-}"
  do
    job_provider="$(printf '%s' "${job_provider}" | tr '[:upper:]' '[:lower:]')"
    [[ "${job_provider}" == "codex" ]] && needs_codex_cli=1
  done

  command -v python3 >/dev/null 2>&1 || missing+=("python3")
  command -v jq      >/dev/null 2>&1 || missing+=("jq")
  command -v git     >/dev/null 2>&1 || missing+=("git")
  command -v claude  >/dev/null 2>&1 || missing+=("claude")
  if [[ "${CODEX_INGEST_CHOICE}" == "1" ]]; then
    command -v sqlite3 >/dev/null 2>&1 || missing+=("sqlite3")
    needs_codex_cli=1
  fi
  if [[ "${needs_codex_cli}" -eq 1 ]]; then
    command -v codex   >/dev/null 2>&1 || missing+=("codex")
  fi

  if [[ "${#missing[@]}" -gt 0 ]]; then
    echo "ERROR: missing required tool(s): ${missing[*]}" >&2
    echo "" >&2
    for tool in "${missing[@]}"; do
      case "${tool}" in
        python3|jq|git|sqlite3)
          if [[ "${platform}" == "Darwin" ]]; then
            echo "  ${tool}: brew install ${tool}" >&2
          else
            echo "  ${tool}: sudo apt install ${tool}    # or your distro's equivalent" >&2
          fi
          ;;
        claude)
          echo "  claude: install Claude Code CLI — https://docs.claude.com/en/docs/claude-code" >&2
          echo "          then run 'claude /login' to authenticate" >&2
          ;;
        codex)
          echo "  codex: install the Codex CLI and run it once so ~/.codex/state_5.sqlite exists" >&2
          ;;
      esac
    done
    exit 1
  fi

  # Git identity (used for auto-commits by the synthesizer and refactor-review).
  # Either global git config OR WORK_WIKI_GIT_NAME / WORK_WIKI_GIT_EMAIL env vars
  # in ~/.claude/settings.json are acceptable, but at install time only the
  # global config exists (settings.json is what we're about to create).
  local gname gemail
  gname="$(git config --global user.name  2>/dev/null || true)"
  gemail="$(git config --global user.email 2>/dev/null || true)"
  if [[ -z "${gname}" || -z "${gemail}" ]]; then
    echo "ERROR: git identity not configured globally" >&2
    echo "  The synthesizer auto-commits as your git user. Configure with:" >&2
    [[ -z "${gname}"  ]] && echo "    git config --global user.name  \"Your Name\"" >&2
    [[ -z "${gemail}" ]] && echo "    git config --global user.email \"you@example.com\"" >&2
    echo "" >&2
    echo "  (Alternatively, set WORK_WIKI_GIT_NAME / WORK_WIKI_GIT_EMAIL in" >&2
    echo "   ~/.claude/settings.json after install.)" >&2
    exit 1
  fi
}
preflight

# --- Verify claude CLI auth by firing a minimal no-tools prompt ---
# Costs one trivial API call (~3 tokens). Opt out with SKIP_AUTH_CHECK=1
# for offline reinstalls or CI runs where the network/auth check is wasteful.
claude_auth_check() {
  if [[ "${SKIP_AUTH_CHECK:-0}" == "1" ]]; then
    echo "Skipping claude auth check (SKIP_AUTH_CHECK=1)"
    return 0
  fi

  echo "Verifying claude auth (one tiny prompt — adds a few seconds)..."

  # Use timeout/gtimeout if available so a hung auth can't block forever.
  # macOS doesn't ship `timeout`; coreutils provides it as `gtimeout`.
  local timeout_cmd=()
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd=(timeout 30)
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd=(gtimeout 30)
  fi

  local out ex=0
  out="$("${timeout_cmd[@]}" claude -p "ok" --allowedTools "" 2>&1)" || ex=$?

  if [[ "${ex}" -ne 0 ]]; then
    echo "ERROR: claude -p failed (exit ${ex})" >&2
    echo "" >&2
    echo "  Last output:" >&2
    echo "${out}" | head -10 | sed 's/^/    /' >&2
    echo "" >&2
    echo "  Likely causes:" >&2
    echo "    - Not authenticated → run: claude /login" >&2
    echo "    - Network unreachable → check connectivity" >&2
    echo "    - API outage → https://status.anthropic.com" >&2
    echo "" >&2
    echo "  Skip this check for offline/CI installs:" >&2
    echo "    SKIP_AUTH_CHECK=1 bash ${BASH_SOURCE[0]} $*" >&2
    exit 1
  fi
}
claude_auth_check "$@"

# Markers in CLAUDE.md
NEW_MARKER="<!-- work-wiki -->"
OLD_MARKER="<!-- work-tracker -->"

HOOK_END_SRC="${SCRIPT_DIR}/hooks/wiki-session-end.sh"
HOOK_END_DST="${HOOKS_DIR}/wiki-session-end.sh"
HOOK_SYNTH_SRC="${SCRIPT_DIR}/hooks/wiki-synthesizer.sh"
HEADLESS_RUNNER_SRC="${SCRIPT_DIR}/scripts/headless-agent-run.sh"
SLACK_PREFETCH_SRC="${SCRIPT_DIR}/scripts/slack-prefetch.py"
LEGACY_UPDATER_SRC="${SCRIPT_DIR}/hooks/wiki-updater.sh"
LEGACY_HOOK_DST="${HOOKS_DIR}/knowledge-session-end.sh"
LEGACY_UPDATER_DST="${HOOKS_DIR}/wiki-updater.sh"
PATCH_FILE="${SCRIPT_DIR}/config/settings-patch.json"

LAUNCHD_TEMPLATE="${SCRIPT_DIR}/config/com.work-wiki.daily.plist.template"
LAUNCHD_DST="${HOME}/Library/LaunchAgents/com.work-wiki.daily.plist"

LAUNCHD_SLACK_TEMPLATE="${SCRIPT_DIR}/config/com.work-wiki.slack-daily.plist.template"
LAUNCHD_SLACK_DST="${HOME}/Library/LaunchAgents/com.work-wiki.slack-daily.plist"
SLACK_INGEST_SRC="${SCRIPT_DIR}/scripts/slack-ingest.sh"

LAUNCHD_GRANOLA_TEMPLATE="${SCRIPT_DIR}/config/com.work-wiki.granola-daily.plist.template"
LAUNCHD_GRANOLA_DST="${HOME}/Library/LaunchAgents/com.work-wiki.granola-daily.plist"
GRANOLA_INGEST_SRC="${SCRIPT_DIR}/scripts/granola-ingest.sh"
GRANOLA_EXTRACT_SRC="${SCRIPT_DIR}/scripts/granola-extract.py"

LAUNCHD_CODEX_TEMPLATE="${SCRIPT_DIR}/config/com.work-wiki.codex-ingest.plist.template"
LAUNCHD_CODEX_DST="${HOME}/Library/LaunchAgents/com.work-wiki.codex-ingest.plist"
CODEX_INGEST_SRC="${SCRIPT_DIR}/scripts/codex-ingest.sh"

LAUNCHD_REFACTOR_TEMPLATE="${SCRIPT_DIR}/config/com.work-wiki.refactor-daily.plist.template"
LAUNCHD_REFACTOR_DST="${HOME}/Library/LaunchAgents/com.work-wiki.refactor-daily.plist"
LEGACY_REFACTOR_DST="${HOME}/Library/LaunchAgents/com.work-wiki.refactor-weekly.plist"
REFACTOR_REVIEW_SRC="${SCRIPT_DIR}/scripts/refactor-review.sh"

# --- Status helpers ---
dir_status() { [[ -d "$1" ]] && echo "already exists" || echo "will create"; }

link_status() {
  local target="$1" expected="$2"
  if [[ -L "${target}" ]]; then
    local cur
    cur="$(readlink "${target}")"
    if [[ "${cur}" == "${expected}" ]]; then
      echo "already correct"
    else
      echo "will replace (currently → ${cur})"
    fi
  elif [[ -e "${target}" ]]; then
    echo "will replace existing file"
  else
    echo "will create"
  fi
}

legacy_hook_status() {
  local found=()
  [[ -L "${LEGACY_HOOK_DST}" || -e "${LEGACY_HOOK_DST}" ]] && found+=("${LEGACY_HOOK_DST}")
  [[ -L "${LEGACY_UPDATER_DST}" || -e "${LEGACY_UPDATER_DST}" ]] && found+=("${LEGACY_UPDATER_DST}")
  [[ -f "${LEGACY_UPDATER_SRC}" ]] && found+=("${LEGACY_UPDATER_SRC} (source-side)")
  if [[ "${#found[@]}" -eq 0 ]]; then
    echo "no legacy artifacts (clean)"
  else
    echo "will remove: ${found[*]}"
  fi
}

daily_status() {
  if [[ "${DAILY_CHOICE}" == "0" ]]; then
    echo "skipped (--no-enable-daily)"
    return
  fi
  if [[ -f "${LAUNCHD_DST}" ]]; then
    echo "${LAUNCHD_DST} already exists — will refresh"
    return
  fi
  case "${DAILY_CHOICE}" in
    1) echo "will render plist → ${LAUNCHD_DST}" ;;
    *)
      if [[ "${ASSUME_YES}" -eq 1 ]]; then
        echo "will render plist → ${LAUNCHD_DST} (default)"
      else
        echo "will be asked"
      fi
      ;;
  esac
}

slack_daily_status() {
  if [[ "${SLACK_DAILY_CHOICE}" == "0" ]]; then
    echo "skipped (--no-enable-slack-daily)"
    return
  fi
  if [[ -f "${LAUNCHD_SLACK_DST}" ]]; then
    echo "${LAUNCHD_SLACK_DST} already exists — will refresh"
    return
  fi
  case "${SLACK_DAILY_CHOICE}" in
    1) echo "will render plist → ${LAUNCHD_SLACK_DST}" ;;
    *)
      if [[ "${ASSUME_YES}" -eq 1 ]]; then
        echo "will render plist → ${LAUNCHD_SLACK_DST} (default)"
      else
        echo "will be asked"
      fi
      ;;
  esac
}

granola_daily_status() {
  if [[ "${GRANOLA_DAILY_CHOICE}" == "0" ]]; then
    echo "skipped (--no-enable-granola-daily)"
    return
  fi
  if [[ -f "${LAUNCHD_GRANOLA_DST}" ]]; then
    echo "${LAUNCHD_GRANOLA_DST} already exists — will refresh"
    return
  fi
  case "${GRANOLA_DAILY_CHOICE}" in
    1) echo "will render plist → ${LAUNCHD_GRANOLA_DST}" ;;
    *)
      if [[ "${ASSUME_YES}" -eq 1 ]]; then
        echo "will render plist → ${LAUNCHD_GRANOLA_DST} (default)"
      else
        echo "will be asked"
      fi
      ;;
  esac
}

refactor_daily_status() {
  local legacy_note=""
  if [[ -f "${LEGACY_REFACTOR_DST}" ]]; then
    legacy_note=" (will also unload+remove legacy ${LEGACY_REFACTOR_DST})"
  fi
  if [[ "${REFACTOR_DAILY_CHOICE}" == "0" ]]; then
    echo "skipped (--no-enable-refactor-daily)${legacy_note}"
    return
  fi
  if [[ -f "${LAUNCHD_REFACTOR_DST}" ]]; then
    echo "${LAUNCHD_REFACTOR_DST} already exists — will refresh${legacy_note}"
    return
  fi
  case "${REFACTOR_DAILY_CHOICE}" in
    1) echo "will render plist → ${LAUNCHD_REFACTOR_DST}${legacy_note}" ;;
    *)
      if [[ "${ASSUME_YES}" -eq 1 ]]; then
        echo "will render plist → ${LAUNCHD_REFACTOR_DST}${legacy_note} (default)"
      else
        echo "will be asked${legacy_note}"
      fi
      ;;
  esac
}

codex_ingest_status() {
  if [[ "${CODEX_INGEST_CHOICE}" == "0" ]]; then
    echo "skipped (--no-enable-codex-ingest)"
    return
  fi
  if [[ -f "${LAUNCHD_CODEX_DST}" ]]; then
    echo "${LAUNCHD_CODEX_DST} already exists — will refresh"
    return
  fi
  case "${CODEX_INGEST_CHOICE}" in
    1) echo "will render plist → ${LAUNCHD_CODEX_DST}" ;;
    *)
      if [[ "${ASSUME_YES}" -eq 1 ]]; then
        echo "will render plist → ${LAUNCHD_CODEX_DST} (default)"
      else
        echo "will be asked"
      fi
      ;;
  esac
}

settings_status() {
  if [[ ! -f "${SETTINGS}" ]]; then
    echo "will create new file with SessionEnd hook"
  elif jq -e '.hooks.SessionEnd[]?.hooks[]? | select(.command? | tostring | test("knowledge-session-end\\.sh"))' "${SETTINGS}" > /dev/null 2>&1; then
    echo "will migrate legacy knowledge-session-end.sh entry"
  elif jq -e '.hooks.SessionEnd[]?.hooks[]? | select(.command? | tostring | test("wiki-session-end\\.sh"))' "${SETTINGS}" > /dev/null 2>&1; then
    echo "already has wiki-session-end.sh entry — will skip"
  elif jq -e '.hooks.SessionEnd' "${SETTINGS}" > /dev/null 2>&1; then
    echo "has unrelated SessionEnd entry — will append"
  else
    echo "will add SessionEnd entry"
  fi
}

claude_md_status() {
  if [[ ! -f "${CLAUDE_MD}" ]]; then
    echo "will create with work-wiki block"
  elif grep -qF "${NEW_MARKER}" "${CLAUDE_MD}"; then
    echo "already has ${NEW_MARKER} — will refresh"
  elif grep -qF "${OLD_MARKER}" "${CLAUDE_MD}"; then
    echo "will replace legacy ${OLD_MARKER} block with ${NEW_MARKER}"
  else
    echo "will append work-wiki block"
  fi
}

codex_config_status() {
  if [[ ! -f "${CODEX_CONFIG}" ]]; then
    echo "will create with developer_instructions work-wiki block"
  elif grep -qF "${NEW_MARKER}" "${CODEX_CONFIG}"; then
    echo "already has ${NEW_MARKER} — will refresh"
  elif grep -Eq '^developer_instructions[[:space:]]*=' "${CODEX_CONFIG}"; then
    echo "will append work-wiki block to existing developer_instructions"
  else
    echo "will add developer_instructions work-wiki block"
  fi
}

settings_has_autopush() {
  [[ -f "${SETTINGS}" ]] && \
    jq -e '.env.WORK_WIKI_AUTO_PUSH == "1" or .env.WORK_WIKI_AUTO_PUSH == "true"' \
       "${SETTINGS}" > /dev/null 2>&1
}

settings_has_legacy_autopush() {
  [[ -f "${SETTINGS}" ]] && \
    jq -e '.env.WORK_TRACKER_AUTO_PUSH == "1" or .env.WORK_TRACKER_AUTO_PUSH == "true"' \
       "${SETTINGS}" > /dev/null 2>&1
}

autopush_status() {
  if settings_has_autopush; then
    echo "${SETTINGS} already has env.WORK_WIKI_AUTO_PUSH — will leave alone"
    return
  fi
  if settings_has_legacy_autopush; then
    echo "will migrate legacy env.WORK_TRACKER_AUTO_PUSH → WORK_WIKI_AUTO_PUSH"
    return
  fi
  case "${AUTO_PUSH_CHOICE}" in
    1) echo "will set env.WORK_WIKI_AUTO_PUSH=\"1\" in ${SETTINGS}" ;;
    0) echo "skipped (--no-auto-push)" ;;
    *)
      if [[ "${ASSUME_YES}" -eq 1 ]]; then
        echo "skipped (use --auto-push to enable in --yes mode)"
      else
        echo "will be asked"
      fi
      ;;
  esac
}

synth_provider_status() {
  if [[ -f "${SETTINGS}" ]] && jq -e --arg provider "${SYNTH_PROVIDER}" '.env.WORK_WIKI_SYNTH_PROVIDER == $provider' "${SETTINGS}" > /dev/null 2>&1; then
    echo "${SETTINGS} already has env.WORK_WIKI_SYNTH_PROVIDER=\"${SYNTH_PROVIDER}\" — will leave alone"
  else
    echo "will set env.WORK_WIKI_SYNTH_PROVIDER=\"${SYNTH_PROVIDER}\" in ${SETTINGS} and launchd plists"
  fi
}

# --- Print plan ---
cat <<EOF
Work-wiki installer — planned actions

  Repo            : ${WORK_WIKI}
  Hooks directory : ${HOOKS_DIR}   [$(dir_status "${HOOKS_DIR}")]
  Log directory   : ${LOG_DIR}    [$(dir_status "${LOG_DIR}")]
  Settings file   : ${SETTINGS}   [$(settings_status)]
  Global CLAUDE.md: ${CLAUDE_MD}   [$(claude_md_status)]
  Codex config    : ${CODEX_CONFIG}   [$(codex_config_status)]

Triage hook symlink:
  ${HOOK_END_DST}
    → ${HOOK_END_SRC}
    [$(link_status "${HOOK_END_DST}" "${HOOK_END_SRC}")]

Legacy cleanup:
  $(legacy_hook_status)

Synthesizer script (invoked directly from the repo, no symlink needed):
  ${HOOK_SYNTH_SRC}

Settings patch source: ${PATCH_FILE}

Auto-push setup:
  WORK_WIKI_AUTO_PUSH in ${SETTINGS} env block
  [$(autopush_status)]

Headless synthesis provider:
  WORK_WIKI_SYNTH_PROVIDER=${SYNTH_PROVIDER}
  [$(synth_provider_status)]

Daily floor (launchd plist at 8pm, default):
  ${LAUNCHD_DST}
  [$(daily_status)]

Slack daily ingest (launchd plist at 8pm, default):
  ${LAUNCHD_SLACK_DST}
  [$(slack_daily_status)]

Granola daily ingest (launchd plist at 8pm, default):
  ${LAUNCHD_GRANOLA_DST}
  [$(granola_daily_status)]

Refactor daily review (launchd plist daily 8:30pm, default):
  ${LAUNCHD_REFACTOR_DST}
  [$(refactor_daily_status)]

Codex ingest (launchd plist every 15 minutes, default):
  ${LAUNCHD_CODEX_DST}
  [$(codex_ingest_status)]

EOF

# --- Confirm ---
if [[ "${ASSUME_YES}" -ne 1 ]]; then
  if [[ ! -t 0 ]]; then
    echo "Non-interactive shell — pass --yes to confirm, or run interactively." >&2
    exit 1
  fi
  read -r -p "Proceed? [y/N] " ans
  case "${ans}" in
    [Yy]|[Yy][Ee][Ss]) ;;
    *) echo "Aborted."; exit 1 ;;
  esac

  if [[ -z "${AUTO_PUSH_CHOICE}" ]] && ! settings_has_autopush && ! settings_has_legacy_autopush; then
    echo ""
    echo "Auto-push: when WORK_WIKI_AUTO_PUSH=1 is set, the synthesizer pushes"
    echo "origin/main after every auto-commit. Failed pushes (no network, auth,"
    echo "remote ahead) log a warning and the commit stays local."
    read -r -p "Set env.WORK_WIKI_AUTO_PUSH=\"1\" in ${SETTINGS}? [y/N] " ans
    case "${ans}" in
      [Yy]|[Yy][Ee][Ss]) AUTO_PUSH_CHOICE=1 ;;
      *)                 AUTO_PUSH_CHOICE=0 ;;
    esac
  fi

  if [[ -z "${DAILY_CHOICE}" && ! -f "${LAUNCHD_DST}" ]]; then
    echo ""
    echo "Daily floor: a launchd plist that fires the synthesizer at 8pm"
    echo "every day, so pending sessions don't sit overnight when the count/age"
    echo "thresholds aren't hit. The plist is written to ~/Library/LaunchAgents/"
    echo "but is NOT loaded automatically — you'll get the load command at the end."
    read -r -p "Render daily plist into ${LAUNCHD_DST}? [y/N] " ans
    case "${ans}" in
      [Yy]|[Yy][Ee][Ss]) DAILY_CHOICE=1 ;;
      *)                 DAILY_CHOICE=0 ;;
    esac
  fi

  if [[ -z "${SLACK_DAILY_CHOICE}" && ! -f "${LAUNCHD_SLACK_DST}" ]]; then
    echo ""
    echo "Slack daily ingest: a launchd plist that runs slack-ingest.sh at"
    echo "8pm daily. It prefetches the user's recent messages and threads into"
    echo "a temporary JSONL bundle, then the configured headless provider folds"
    echo "durable signal into wiki pages. Process-and-discard — only a single"
    echo "timestamp cursor is persisted. Requires WORK_WIKI_SLACK_TOKEN."
    read -r -p "Render Slack-daily plist into ${LAUNCHD_SLACK_DST}? [y/N] " ans
    case "${ans}" in
      [Yy]|[Yy][Ee][Ss]) SLACK_DAILY_CHOICE=1 ;;
      *)                 SLACK_DAILY_CHOICE=0 ;;
    esac
  fi

  if [[ -z "${REFACTOR_DAILY_CHOICE}" && ! -f "${LAUNCHD_REFACTOR_DST}" ]]; then
    echo ""
    echo "Refactor daily review: a launchd plist that runs refactor-review.sh"
    echo "every day at 8:30pm. Runs the configured headless provider over the cheap"
    echo "detectors, scans for structural drift (renames in flight, resolved open"
    echo "questions, rotting synthesis items, recent-activity overflow, SPLIT/DEDUP"
    echo "intents recorded by the synthesizer), and AUTO-APPLIES each finding that"
    echo "meets the per-category high-confidence gate. No proposals file is produced;"
    echo "commits are pushed when WORK_WIKI_AUTO_PUSH=1."
    read -r -p "Render refactor-daily plist into ${LAUNCHD_REFACTOR_DST}? [y/N] " ans
    case "${ans}" in
      [Yy]|[Yy][Ee][Ss]) REFACTOR_DAILY_CHOICE=1 ;;
      *)                 REFACTOR_DAILY_CHOICE=0 ;;
    esac
  fi

  if [[ -z "${CODEX_INGEST_CHOICE}" && ! -f "${LAUNCHD_CODEX_DST}" ]]; then
    echo ""
    echo "Codex ingest: a launchd plist that polls ~/.codex/state_5.sqlite"
    echo "every 15 minutes, enqueues idle changed Codex rollout JSONL files, and"
    echo "reuses the same batched synthesizer as Claude transcripts."
    read -r -p "Render Codex-ingest plist into ${LAUNCHD_CODEX_DST}? [y/N] " ans
    case "${ans}" in
      [Yy]|[Yy][Ee][Ss]) CODEX_INGEST_CHOICE=1 ;;
      *)                 CODEX_INGEST_CHOICE=0 ;;
    esac
  fi

  if [[ -z "${GRANOLA_DAILY_CHOICE}" && ! -f "${LAUNCHD_GRANOLA_DST}" ]]; then
    echo ""
    echo "Granola daily ingest: a launchd plist that runs granola-ingest.sh"
    echo "at 8pm daily. It polls Granola's Personal API for notes updated since"
    echo "the last successful run, includes transcripts in a temporary bundle for"
    echo "synthesis, then deletes raw note content. Requires"
    echo "WORK_WIKI_GRANOLA_API_KEY in the environment."
    read -r -p "Render Granola-daily plist into ${LAUNCHD_GRANOLA_DST}? [y/N] " ans
    case "${ans}" in
      [Yy]|[Yy][Ee][Ss]) GRANOLA_DAILY_CHOICE=1 ;;
      *)                 GRANOLA_DAILY_CHOICE=0 ;;
    esac
  fi
fi

# --- Execute ---
echo ""
echo "Installing..."

mkdir -p "${HOOKS_DIR}" "${LOG_DIR}"

chmod +x "${HOOK_END_SRC}" "${HOOK_SYNTH_SRC}"
[[ -f "${CODEX_INGEST_SRC}" ]] && chmod +x "${CODEX_INGEST_SRC}" "${SCRIPT_DIR}/scripts/codex-extract.py"
[[ -f "${GRANOLA_INGEST_SRC}" ]] && chmod +x "${GRANOLA_INGEST_SRC}" "${GRANOLA_EXTRACT_SRC}"
ln -sf "${HOOK_END_SRC}" "${HOOK_END_DST}"
echo "✓ Symlinked $(basename "${HOOK_END_DST}")"

# Remove legacy hook symlink
if [[ -L "${LEGACY_HOOK_DST}" || -e "${LEGACY_HOOK_DST}" ]]; then
  rm -f "${LEGACY_HOOK_DST}"
  echo "✓ Removed legacy ${LEGACY_HOOK_DST}"
fi

# Remove legacy wiki-updater.sh artifacts (replaced by wiki-synthesizer.sh)
if [[ -L "${LEGACY_UPDATER_DST}" || -e "${LEGACY_UPDATER_DST}" ]]; then
  rm -f "${LEGACY_UPDATER_DST}"
  echo "✓ Removed legacy ${LEGACY_UPDATER_DST}"
fi
if [[ -f "${LEGACY_UPDATER_SRC}" ]]; then
  rm -f "${LEGACY_UPDATER_SRC}"
  echo "✓ Removed legacy ${LEGACY_UPDATER_SRC}"
fi

if [[ ! -f "${SETTINGS}" ]]; then
  echo '{"hooks":{}}' > "${SETTINGS}"
  echo "✓ Created ${SETTINGS}"
fi

# Migrate or install SessionEnd hook entry
TMP="$(mktemp)"
if jq -e '.hooks.SessionEnd[]?.hooks[]? | select(.command? | tostring | test("knowledge-session-end\\.sh"))' "${SETTINGS}" > /dev/null 2>&1; then
  # Rewrite legacy command paths
  jq '(.hooks.SessionEnd[]?.hooks[]? | select(.command? | tostring | test("knowledge-session-end\\.sh")) | .command) |= "~/.claude/hooks/wiki-session-end.sh"' \
    "${SETTINGS}" > "${TMP}"
  mv "${TMP}" "${SETTINGS}"
  echo "✓ Migrated legacy knowledge-session-end.sh entry → wiki-session-end.sh"
elif ! jq -e '.hooks.SessionEnd[]?.hooks[]? | select(.command? | tostring | test("wiki-session-end\\.sh"))' "${SETTINGS}" > /dev/null 2>&1; then
  jq --slurpfile patch "${PATCH_FILE}" '
    .hooks = (.hooks // {})
    | .hooks.SessionEnd = ((.hooks.SessionEnd // []) + $patch[0].SessionEnd)
  ' "${SETTINGS}" > "${TMP}"
  mv "${TMP}" "${SETTINGS}"
  echo "✓ Added SessionEnd hook to ${SETTINGS}"
else
  rm -f "${TMP}"
  echo "✓ SessionEnd hook already present in ${SETTINGS} — skipped"
fi

# Migrate / install CLAUDE.md block
NEW_BLOCK_TMP="$(mktemp)"
cat > "${NEW_BLOCK_TMP}" <<EOF

## Work Wiki ${NEW_MARKER}

A persistent knowledge wiki of work context lives at \`${WORK_WIKI}/\`. Read \`wiki/README.md\` for the entry point and \`SCHEMA.md\` for the rules.

When this session surfaces genuinely new entities (projects, people, technologies), concepts (decisions, recurring patterns), or open questions worth recording, update the relevant \`wiki/\` pages directly. Routine context is folded in automatically by the SessionEnd hook; do not duplicate it.
EOF
NEW_BLOCK="$(cat "${NEW_BLOCK_TMP}")"
rm -f "${NEW_BLOCK_TMP}"

mkdir -p "$(dirname "${CLAUDE_MD}")"
[[ -f "${CLAUDE_MD}" ]] || touch "${CLAUDE_MD}"

if grep -qF "${NEW_MARKER}" "${CLAUDE_MD}"; then
  # Refresh: replace the block in place. Use python for marker-to-EOF replace since portable sed across macOS/linux is finicky.
  CLAUDE_MD_PATH="${CLAUDE_MD}" NEW_BLOCK_VAR="${NEW_BLOCK}" NEW_MARKER_VAR="${NEW_MARKER}" python3 <<'PYEOF'
import os, re
path = os.environ["CLAUDE_MD_PATH"]
new_block = os.environ["NEW_BLOCK_VAR"]
marker = os.environ["NEW_MARKER_VAR"]
with open(path) as f:
    txt = f.read()
# Match from "## " line containing marker up to the next "## " (or EOF)
pattern = re.compile(r"\n## [^\n]*" + re.escape(marker) + r".*?(?=\n## |\Z)", re.DOTALL)
new_txt, n = pattern.subn(new_block.rstrip("\n"), txt)
if n == 0:
    new_txt = txt.rstrip("\n") + "\n" + new_block + "\n"
with open(path, "w") as f:
    f.write(new_txt.rstrip("\n") + "\n")
PYEOF
  echo "✓ Refreshed ${NEW_MARKER} block in ${CLAUDE_MD}"
elif grep -qF "${OLD_MARKER}" "${CLAUDE_MD}"; then
  CLAUDE_MD_PATH="${CLAUDE_MD}" NEW_BLOCK_VAR="${NEW_BLOCK}" OLD_MARKER_VAR="${OLD_MARKER}" python3 <<'PYEOF'
import os, re
path = os.environ["CLAUDE_MD_PATH"]
new_block = os.environ["NEW_BLOCK_VAR"]
old_marker = os.environ["OLD_MARKER_VAR"]
with open(path) as f:
    txt = f.read()
pattern = re.compile(r"\n## [^\n]*" + re.escape(old_marker) + r".*?(?=\n## |\Z)", re.DOTALL)
new_txt, n = pattern.subn(new_block.rstrip("\n"), txt)
with open(path, "w") as f:
    f.write(new_txt.rstrip("\n") + "\n")
PYEOF
  echo "✓ Replaced legacy ${OLD_MARKER} block with ${NEW_MARKER}"
else
  printf '%s\n' "${NEW_BLOCK}" >> "${CLAUDE_MD}"
  echo "✓ Appended work-wiki reference to ${CLAUDE_MD}"
fi

# Migrate / install Codex global developer instructions block. Codex has no
# include mechanism in config.toml, so preserve any existing instructions and
# splice the Work Wiki block into the top-level developer_instructions string.
CODEX_BLOCK="${NEW_BLOCK}"
mkdir -p "$(dirname "${CODEX_CONFIG}")"
python3 "${SCRIPT_DIR}/scripts/codex-config-instructions.py" install \
  --config "${CODEX_CONFIG}" \
  --marker "${NEW_MARKER}" \
  --block "${CODEX_BLOCK}"
echo "✓ Installed work-wiki reference into ${CODEX_CONFIG} developer_instructions"

# Migrate / set auto-push env var
if settings_has_legacy_autopush && ! settings_has_autopush; then
  TMP="$(mktemp)"
  jq '
    .env = (.env // {})
    | .env.WORK_WIKI_AUTO_PUSH = (.env.WORK_TRACKER_AUTO_PUSH | tostring)
    | del(.env.WORK_TRACKER_AUTO_PUSH)
  ' "${SETTINGS}" > "${TMP}"
  mv "${TMP}" "${SETTINGS}"
  echo "✓ Migrated env.WORK_TRACKER_AUTO_PUSH → WORK_WIKI_AUTO_PUSH"
elif [[ "${AUTO_PUSH_CHOICE}" == "1" ]] && ! settings_has_autopush; then
  TMP="$(mktemp)"
  jq '.env = (.env // {}) | .env.WORK_WIKI_AUTO_PUSH = "1"' "${SETTINGS}" > "${TMP}"
  mv "${TMP}" "${SETTINGS}"
  echo "✓ Set env.WORK_WIKI_AUTO_PUSH=\"1\" in ${SETTINGS}"
fi

TMP="$(mktemp)"
jq --arg provider "${SYNTH_PROVIDER}" '.env = (.env // {}) | .env.WORK_WIKI_SYNTH_PROVIDER = $provider' "${SETTINGS}" > "${TMP}"
mv "${TMP}" "${SETTINGS}"
echo "✓ Set env.WORK_WIKI_SYNTH_PROVIDER=\"${SYNTH_PROVIDER}\" in ${SETTINGS}"

# Idempotent reload: unload first (in case it's already loaded with a stale
# version), then load. Tolerates non-loaded state. Args: <label> <plist-path>.
launchctl_reload() {
  local label="$1" plist="$2"
  if launchctl list 2>/dev/null | grep -q "${label}"; then
    launchctl unload "${plist}" 2>/dev/null || true
  fi
  if launchctl load -w "${plist}" 2>/dev/null; then
    echo "✓ Loaded ${label} via launchctl"
    return 0
  else
    echo "WARN: launchctl load -w ${plist} failed — load it manually later"
    return 1
  fi
}

# Render daily launchd plist if opted in
if [[ "${DAILY_CHOICE}" == "1" ]]; then
  if [[ ! -f "${LAUNCHD_TEMPLATE}" ]]; then
    echo "WARN: launchd template not found at ${LAUNCHD_TEMPLATE} — skipping daily plist"
  else
    chmod +x "${HOOK_SYNTH_SRC}" "${HEADLESS_RUNNER_SRC}"
    mkdir -p "$(dirname "${LAUNCHD_DST}")"
    LAUNCHD_TEMPLATE_PATH="${LAUNCHD_TEMPLATE}" \
    LAUNCHD_DST_PATH="${LAUNCHD_DST}" \
    HOME_VAL="${HOME}" \
    WORK_WIKI_VAL="${WORK_WIKI}" \
    SYNTH_PROVIDER_VAL="${SYNTH_PROVIDER}" \
    python3 <<'PYEOF'
import os
src = os.environ["LAUNCHD_TEMPLATE_PATH"]
dst = os.environ["LAUNCHD_DST_PATH"]
with open(src) as f:
    txt = f.read()
txt = txt.replace("__HOME__", os.environ["HOME_VAL"])
txt = txt.replace("__WORK_WIKI__", os.environ["WORK_WIKI_VAL"])
txt = txt.replace("__SYNTH_PROVIDER__", os.environ["SYNTH_PROVIDER_VAL"])
with open(dst, "w") as f:
    f.write(txt)
PYEOF
    echo "✓ Rendered daily plist → ${LAUNCHD_DST}"
    DAILY_INSTALLED=1
    launchctl_reload "com.work-wiki.daily" "${LAUNCHD_DST}" && DAILY_LOADED=1 || DAILY_LOADED=0
  fi
fi

# Render Slack-daily launchd plist if opted in
if [[ "${SLACK_DAILY_CHOICE}" == "1" ]]; then
  if [[ ! -f "${LAUNCHD_SLACK_TEMPLATE}" ]]; then
    echo "WARN: launchd template not found at ${LAUNCHD_SLACK_TEMPLATE} — skipping Slack-daily plist"
  elif [[ ! -f "${SLACK_INGEST_SRC}" ]]; then
    echo "WARN: slack-ingest.sh not found at ${SLACK_INGEST_SRC} — skipping Slack-daily plist"
  else
    chmod +x "${SLACK_INGEST_SRC}" "${SLACK_PREFETCH_SRC}" "${HEADLESS_RUNNER_SRC}"
    mkdir -p "$(dirname "${LAUNCHD_SLACK_DST}")"
    LAUNCHD_TEMPLATE_PATH="${LAUNCHD_SLACK_TEMPLATE}" \
    LAUNCHD_DST_PATH="${LAUNCHD_SLACK_DST}" \
    HOME_VAL="${HOME}" \
    WORK_WIKI_VAL="${WORK_WIKI}" \
    SYNTH_PROVIDER_VAL="${SYNTH_PROVIDER}" \
    python3 <<'PYEOF'
import os
src = os.environ["LAUNCHD_TEMPLATE_PATH"]
dst = os.environ["LAUNCHD_DST_PATH"]
with open(src) as f:
    txt = f.read()
txt = txt.replace("__HOME__", os.environ["HOME_VAL"])
txt = txt.replace("__WORK_WIKI__", os.environ["WORK_WIKI_VAL"])
txt = txt.replace("__SYNTH_PROVIDER__", os.environ["SYNTH_PROVIDER_VAL"])
with open(dst, "w") as f:
    f.write(txt)
PYEOF
    echo "✓ Rendered Slack-daily plist → ${LAUNCHD_SLACK_DST}"
    SLACK_DAILY_INSTALLED=1
    launchctl_reload "com.work-wiki.slack-daily" "${LAUNCHD_SLACK_DST}" && SLACK_DAILY_LOADED=1 || SLACK_DAILY_LOADED=0
  fi
fi

# Render Granola-daily launchd plist if opted in
if [[ "${GRANOLA_DAILY_CHOICE}" == "1" ]]; then
  if [[ ! -f "${LAUNCHD_GRANOLA_TEMPLATE}" ]]; then
    echo "WARN: launchd template not found at ${LAUNCHD_GRANOLA_TEMPLATE} — skipping Granola-daily plist"
  elif [[ ! -f "${GRANOLA_INGEST_SRC}" || ! -f "${GRANOLA_EXTRACT_SRC}" ]]; then
    echo "WARN: Granola ingest scripts not found — skipping Granola-daily plist"
  else
    chmod +x "${GRANOLA_INGEST_SRC}" "${GRANOLA_EXTRACT_SRC}" "${HEADLESS_RUNNER_SRC}"
    mkdir -p "$(dirname "${LAUNCHD_GRANOLA_DST}")"
    LAUNCHD_TEMPLATE_PATH="${LAUNCHD_GRANOLA_TEMPLATE}" \
    LAUNCHD_DST_PATH="${LAUNCHD_GRANOLA_DST}" \
    HOME_VAL="${HOME}" \
    WORK_WIKI_VAL="${WORK_WIKI}" \
    SYNTH_PROVIDER_VAL="${SYNTH_PROVIDER}" \
    python3 <<'PYEOF'
import os
src = os.environ["LAUNCHD_TEMPLATE_PATH"]
dst = os.environ["LAUNCHD_DST_PATH"]
with open(src) as f:
    txt = f.read()
txt = txt.replace("__HOME__", os.environ["HOME_VAL"])
txt = txt.replace("__WORK_WIKI__", os.environ["WORK_WIKI_VAL"])
txt = txt.replace("__SYNTH_PROVIDER__", os.environ["SYNTH_PROVIDER_VAL"])
with open(dst, "w") as f:
    f.write(txt)
PYEOF
    echo "✓ Rendered Granola-daily plist → ${LAUNCHD_GRANOLA_DST}"
    GRANOLA_DAILY_INSTALLED=1
    launchctl_reload "com.work-wiki.granola-daily" "${LAUNCHD_GRANOLA_DST}" && GRANOLA_DAILY_LOADED=1 || GRANOLA_DAILY_LOADED=0
  fi
fi

# Render Codex-ingest launchd plist if opted in
if [[ "${CODEX_INGEST_CHOICE}" == "1" ]]; then
  if [[ ! -f "${LAUNCHD_CODEX_TEMPLATE}" ]]; then
    echo "WARN: launchd template not found at ${LAUNCHD_CODEX_TEMPLATE} — skipping Codex-ingest plist"
  elif [[ ! -f "${CODEX_INGEST_SRC}" ]]; then
    echo "WARN: codex-ingest.sh not found at ${CODEX_INGEST_SRC} — skipping Codex-ingest plist"
  elif ! command -v sqlite3 >/dev/null 2>&1 || ! command -v codex >/dev/null 2>&1; then
    echo "WARN: sqlite3 and codex must be on PATH to enable Codex ingest — skipping Codex-ingest plist"
  else
    chmod +x "${CODEX_INGEST_SRC}" "${SCRIPT_DIR}/scripts/codex-extract.py"
    mkdir -p "$(dirname "${LAUNCHD_CODEX_DST}")"
    LAUNCHD_TEMPLATE_PATH="${LAUNCHD_CODEX_TEMPLATE}" \
    LAUNCHD_DST_PATH="${LAUNCHD_CODEX_DST}" \
    HOME_VAL="${HOME}" \
    WORK_WIKI_VAL="${WORK_WIKI}" \
    SYNTH_PROVIDER_VAL="${SYNTH_PROVIDER}" \
    python3 <<'PYEOF'
import os
src = os.environ["LAUNCHD_TEMPLATE_PATH"]
dst = os.environ["LAUNCHD_DST_PATH"]
with open(src) as f:
    txt = f.read()
txt = txt.replace("__HOME__", os.environ["HOME_VAL"])
txt = txt.replace("__WORK_WIKI__", os.environ["WORK_WIKI_VAL"])
txt = txt.replace("__SYNTH_PROVIDER__", os.environ["SYNTH_PROVIDER_VAL"])
with open(dst, "w") as f:
    f.write(txt)
PYEOF
    echo "✓ Rendered Codex-ingest plist → ${LAUNCHD_CODEX_DST}"
    CODEX_INGEST_INSTALLED=1
    launchctl_reload "com.work-wiki.codex-ingest" "${LAUNCHD_CODEX_DST}" && CODEX_INGEST_LOADED=1 || CODEX_INGEST_LOADED=0
  fi
fi

# Migrate legacy refactor-weekly plist (predecessor of refactor-daily) if present
if [[ -f "${LEGACY_REFACTOR_DST}" ]]; then
  launchctl unload "${LEGACY_REFACTOR_DST}" 2>/dev/null || true
  rm -f "${LEGACY_REFACTOR_DST}"
  echo "✓ Removed legacy refactor-weekly plist (replaced by refactor-daily)"
fi

# Render refactor-daily launchd plist if opted in
if [[ "${REFACTOR_DAILY_CHOICE}" == "1" ]]; then
  if [[ ! -f "${LAUNCHD_REFACTOR_TEMPLATE}" ]]; then
    echo "WARN: launchd template not found at ${LAUNCHD_REFACTOR_TEMPLATE} — skipping refactor-daily plist"
  elif [[ ! -f "${REFACTOR_REVIEW_SRC}" ]]; then
    echo "WARN: refactor-review.sh not found at ${REFACTOR_REVIEW_SRC} — skipping refactor-daily plist"
  else
    chmod +x "${REFACTOR_REVIEW_SRC}" "${HEADLESS_RUNNER_SRC}"
    mkdir -p "$(dirname "${LAUNCHD_REFACTOR_DST}")"
    LAUNCHD_TEMPLATE_PATH="${LAUNCHD_REFACTOR_TEMPLATE}" \
    LAUNCHD_DST_PATH="${LAUNCHD_REFACTOR_DST}" \
    HOME_VAL="${HOME}" \
    WORK_WIKI_VAL="${WORK_WIKI}" \
    SYNTH_PROVIDER_VAL="${SYNTH_PROVIDER}" \
    python3 <<'PYEOF'
import os
src = os.environ["LAUNCHD_TEMPLATE_PATH"]
dst = os.environ["LAUNCHD_DST_PATH"]
with open(src) as f:
    txt = f.read()
txt = txt.replace("__HOME__", os.environ["HOME_VAL"])
txt = txt.replace("__WORK_WIKI__", os.environ["WORK_WIKI_VAL"])
txt = txt.replace("__SYNTH_PROVIDER__", os.environ["SYNTH_PROVIDER_VAL"])
with open(dst, "w") as f:
    f.write(txt)
PYEOF
    echo "✓ Rendered refactor-daily plist → ${LAUNCHD_REFACTOR_DST}"
    REFACTOR_DAILY_INSTALLED=1
    launchctl_reload "com.work-wiki.refactor-daily" "${LAUNCHD_REFACTOR_DST}" && REFACTOR_DAILY_LOADED=1 || REFACTOR_DAILY_LOADED=0
  fi
fi

echo ""
echo "Installation complete."
echo "  Hook logs        → ${LOG_DIR}/wiki-session-end.log"
echo "  Synthesizer logs → ${LOG_DIR}/wiki-synthesizer.log"
echo "  Wiki repo        → ${WORK_WIKI}/"
if [[ "${DAILY_INSTALLED:-0}" == "1" ]]; then
  echo ""
  if [[ "${DAILY_LOADED:-0}" == "1" ]]; then
    echo "Daily floor plist installed and loaded — fires at 8pm daily."
  else
    echo "Daily floor plist installed but NOT loaded. To enable it, run:"
    echo "  launchctl load -w ${LAUNCHD_DST}"
  fi
  echo "To unload later:"
  echo "  launchctl unload -w ${LAUNCHD_DST}"
fi
if [[ "${SLACK_DAILY_INSTALLED:-0}" == "1" ]]; then
  echo ""
  if [[ "${SLACK_DAILY_LOADED:-0}" == "1" ]]; then
    echo "Slack-daily plist installed and loaded — fires at 8pm daily."
  else
    echo "Slack-daily plist installed but NOT loaded. To enable it, run:"
    echo "  launchctl load -w ${LAUNCHD_SLACK_DST}"
  fi
  echo "To unload later:"
  echo "  launchctl unload -w ${LAUNCHD_SLACK_DST}"
  echo ""
  echo "Note: requires WORK_WIKI_SLACK_TOKEN with Slack Web API access for"
  echo "auth.test, search.messages, and conversations.replies."
fi
if [[ "${GRANOLA_DAILY_INSTALLED:-0}" == "1" ]]; then
  echo ""
  if [[ "${GRANOLA_DAILY_LOADED:-0}" == "1" ]]; then
    echo "Granola-daily plist installed and loaded — fires at 8pm daily."
  else
    echo "Granola-daily plist installed but NOT loaded. To enable it, run:"
    echo "  launchctl load -w ${LAUNCHD_GRANOLA_DST}"
  fi
  echo "To unload later:"
  echo "  launchctl unload -w ${LAUNCHD_GRANOLA_DST}"
  echo "Log:"
  echo "  ${LOG_DIR}/granola-ingest.log"
fi
if [[ "${CODEX_INGEST_INSTALLED:-0}" == "1" ]]; then
  echo ""
  if [[ "${CODEX_INGEST_LOADED:-0}" == "1" ]]; then
    echo "Codex-ingest plist installed and loaded — polls every 15 minutes."
  else
    echo "Codex-ingest plist installed but NOT loaded. To enable it, run:"
    echo "  launchctl load -w ${LAUNCHD_CODEX_DST}"
  fi
  echo "To unload later:"
  echo "  launchctl unload -w ${LAUNCHD_CODEX_DST}"
  echo "Log:"
  echo "  ${LOG_DIR}/wiki-codex-ingest.log"
fi
if [[ "${REFACTOR_DAILY_INSTALLED:-0}" == "1" ]]; then
  echo ""
  if [[ "${REFACTOR_DAILY_LOADED:-0}" == "1" ]]; then
    echo "Refactor-daily plist installed and loaded — fires daily at 8:30pm."
  else
    echo "Refactor-daily plist installed but NOT loaded. To enable it, run:"
    echo "  launchctl load -w ${LAUNCHD_REFACTOR_DST}"
  fi
  echo "To unload later:"
  echo "  launchctl unload -w ${LAUNCHD_REFACTOR_DST}"
fi
