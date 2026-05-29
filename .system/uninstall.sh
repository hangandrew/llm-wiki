#!/usr/bin/env bash
# Reverse the work-wiki install. Removes the SessionEnd hook, settings.json
# entries, the Claude/Codex context blocks, and (if installed) launchd plists.
# Leaves the wiki repo and its git history alone — those are user content.
#
# Idempotent and non-destructive of user data: only touches files this
# installer/system created.

set -euo pipefail

ASSUME_YES=0
KEEP_DAILY=0
KEEP_SLACK_DAILY=0
KEEP_GRANOLA_DAILY=0
KEEP_REFACTOR_DAILY=0
KEEP_CODEX_INGEST=0
KEEP_SETTINGS_ENV=0
for arg in "$@"; do
  case "${arg}" in
    -y|--yes) ASSUME_YES=1 ;;
    --keep-daily) KEEP_DAILY=1 ;;
    --keep-slack-daily) KEEP_SLACK_DAILY=1 ;;
    --keep-granola-daily) KEEP_GRANOLA_DAILY=1 ;;
    --keep-refactor-daily|--keep-refactor-weekly) KEEP_REFACTOR_DAILY=1 ;;
    --keep-codex-ingest) KEEP_CODEX_INGEST=1 ;;
    --keep-settings-env) KEEP_SETTINGS_ENV=1 ;;
    -h|--help)
      cat <<'EOF'
Usage: uninstall.sh [-y|--yes] [--keep-daily] [--keep-slack-daily] [--keep-granola-daily] [--keep-refactor-daily] [--keep-codex-ingest] [--keep-settings-env]
  -y, --yes                  Skip the confirmation prompt
      --keep-daily           Don't touch the synthesizer daily launchd plist
      --keep-slack-daily     Don't touch the Slack-ingest daily launchd plist
      --keep-granola-daily   Don't touch the Granola-ingest daily launchd plist
      --keep-refactor-daily  Don't touch the refactor-review daily launchd plist
                             (legacy --keep-refactor-weekly is still accepted)
      --keep-codex-ingest    Don't touch the Codex-ingest launchd plist
      --keep-settings-env    Don't strip env.WORK_WIKI_* from ~/.claude/settings.json
  -h, --help                 Show this help

This removes only configuration and background processes. The wiki
itself — repo, content, git history, resume cursors — stays.
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
WORK_WIKI="$(dirname "${SCRIPT_DIR}")"
HOOKS_DIR="${HOME}/.claude/hooks"
SETTINGS="${HOME}/.claude/settings.json"
CLAUDE_MD="${HOME}/.claude/CLAUDE.md"
CODEX_CONFIG="${HOME}/.codex/config.toml"

NEW_MARKER="<!-- work-wiki -->"
OLD_MARKER="<!-- work-tracker -->"

HOOK_END_DST="${HOOKS_DIR}/wiki-session-end.sh"
LEGACY_HOOK_DST="${HOOKS_DIR}/knowledge-session-end.sh"
LEGACY_UPDATER_DST="${HOOKS_DIR}/wiki-updater.sh"

LAUNCHD_DST="${HOME}/Library/LaunchAgents/com.work-wiki.daily.plist"
LAUNCHD_LABEL="com.work-wiki.daily"

LAUNCHD_SLACK_DST="${HOME}/Library/LaunchAgents/com.work-wiki.slack-daily.plist"
LAUNCHD_SLACK_LABEL="com.work-wiki.slack-daily"

LAUNCHD_GRANOLA_DST="${HOME}/Library/LaunchAgents/com.work-wiki.granola-daily.plist"
LAUNCHD_GRANOLA_LABEL="com.work-wiki.granola-daily"

LAUNCHD_CODEX_DST="${HOME}/Library/LaunchAgents/com.work-wiki.codex-ingest.plist"
LAUNCHD_CODEX_LABEL="com.work-wiki.codex-ingest"

LAUNCHD_REFACTOR_DST="${HOME}/Library/LaunchAgents/com.work-wiki.refactor-daily.plist"
LAUNCHD_REFACTOR_LABEL="com.work-wiki.refactor-daily"
LEGACY_REFACTOR_DST="${HOME}/Library/LaunchAgents/com.work-wiki.refactor-weekly.plist"
LEGACY_REFACTOR_LABEL="com.work-wiki.refactor-weekly"

SLACK_LOCK_DIR="${WORK_WIKI}/.system/state/slack-ingest.lock"
GRANOLA_LOCK_DIR="${WORK_WIKI}/.system/state/granola-ingest.lock"
REFACTOR_LOCK_DIR="${WORK_WIKI}/.refactor-review-lock"

join_actions() {
  local out="" item
  for item in "$@"; do
    if [[ -n "${out}" ]]; then
      out+=", "
    fi
    out+="${item}"
  done
  printf '%s\n' "${out}"
}

codex_ingest_status() {
  if [[ "${KEEP_CODEX_INGEST}" -eq 1 ]]; then
    echo "skipped (--keep-codex-ingest)"
    return
  fi
  local present=0 loaded=0
  [[ -f "${LAUNCHD_CODEX_DST}" ]] && present=1
  if launchctl list 2>/dev/null | grep -q "${LAUNCHD_CODEX_LABEL}"; then loaded=1; fi
  if [[ "${present}" -eq 0 && "${loaded}" -eq 0 ]]; then
    echo "absent"
  else
    local actions=()
    [[ "${loaded}" -eq 1 ]] && actions+=("unload via launchctl")
    [[ "${present}" -eq 1 ]] && actions+=("remove ${LAUNCHD_CODEX_DST}")
    join_actions "${actions[@]}"
  fi
}

# --- Status helpers ---
hook_status() {
  if [[ -L "${HOOK_END_DST}" || -e "${HOOK_END_DST}" ]]; then echo "will remove ${HOOK_END_DST}"; else echo "absent"; fi
}

settings_status() {
  if [[ ! -f "${SETTINGS}" ]]; then
    echo "no settings.json — nothing to do"
    return
  fi
  local actions=()
  if jq -e '.hooks.SessionEnd[]?.hooks[]? | select(.command? | tostring | test("wiki-session-end\\.sh|knowledge-session-end\\.sh"))' "${SETTINGS}" > /dev/null 2>&1; then
    actions+=("strip wiki SessionEnd entry")
  fi
  if [[ "${KEEP_SETTINGS_ENV}" -ne 1 ]]; then
    if jq -e '(.env // {}) | to_entries | map(select(.key | startswith("WORK_WIKI_") or startswith("WORK_TRACKER_"))) | length > 0' "${SETTINGS}" > /dev/null 2>&1; then
      actions+=("strip env.WORK_WIKI_* / WORK_TRACKER_* keys")
    fi
  fi
  if [[ "${#actions[@]}" -eq 0 ]]; then
    echo "nothing to strip"
  else
    join_actions "${actions[@]}"
  fi
}

claude_md_status() {
  if [[ ! -f "${CLAUDE_MD}" ]]; then echo "absent"; return; fi
  if grep -qF "${NEW_MARKER}" "${CLAUDE_MD}"; then
    echo "will remove ${NEW_MARKER} block"
  elif grep -qF "${OLD_MARKER}" "${CLAUDE_MD}"; then
    echo "will remove legacy ${OLD_MARKER} block"
  else
    echo "no work-wiki block present"
  fi
}

codex_config_status() {
  if [[ ! -f "${CODEX_CONFIG}" ]]; then echo "absent"; return; fi
  if grep -qF "${NEW_MARKER}" "${CODEX_CONFIG}"; then
    echo "will remove ${NEW_MARKER} block from developer_instructions"
  else
    echo "no work-wiki block present"
  fi
}

daily_status() {
  if [[ "${KEEP_DAILY}" -eq 1 ]]; then
    echo "skipped (--keep-daily)"
    return
  fi
  local present=0 loaded=0
  [[ -f "${LAUNCHD_DST}" ]] && present=1
  if launchctl list 2>/dev/null | grep -q "${LAUNCHD_LABEL}"; then loaded=1; fi
  if [[ "${present}" -eq 0 && "${loaded}" -eq 0 ]]; then
    echo "absent"
  else
    local actions=()
    [[ "${loaded}" -eq 1 ]] && actions+=("unload via launchctl")
    [[ "${present}" -eq 1 ]] && actions+=("remove ${LAUNCHD_DST}")
    join_actions "${actions[@]}"
  fi
}

slack_daily_status() {
  if [[ "${KEEP_SLACK_DAILY}" -eq 1 ]]; then
    echo "skipped (--keep-slack-daily)"
    return
  fi
  local present=0 loaded=0 lock=0
  [[ -f "${LAUNCHD_SLACK_DST}" ]] && present=1
  if launchctl list 2>/dev/null | grep -q "${LAUNCHD_SLACK_LABEL}"; then loaded=1; fi
  [[ -d "${SLACK_LOCK_DIR}" ]] && lock=1
  if [[ "${present}" -eq 0 && "${loaded}" -eq 0 && "${lock}" -eq 0 ]]; then
    echo "absent"
  else
    local actions=()
    [[ "${loaded}" -eq 1 ]] && actions+=("unload via launchctl")
    [[ "${present}" -eq 1 ]] && actions+=("remove ${LAUNCHD_SLACK_DST}")
    [[ "${lock}" -eq 1 ]] && actions+=("clear stale lock dir")
    join_actions "${actions[@]}"
  fi
}

granola_daily_status() {
  if [[ "${KEEP_GRANOLA_DAILY}" -eq 1 ]]; then
    echo "skipped (--keep-granola-daily)"
    return
  fi
  local present=0 loaded=0 lock=0
  [[ -f "${LAUNCHD_GRANOLA_DST}" ]] && present=1
  if launchctl list 2>/dev/null | grep -q "${LAUNCHD_GRANOLA_LABEL}"; then loaded=1; fi
  [[ -d "${GRANOLA_LOCK_DIR}" ]] && lock=1
  if [[ "${present}" -eq 0 && "${loaded}" -eq 0 && "${lock}" -eq 0 ]]; then
    echo "absent"
  else
    local actions=()
    [[ "${loaded}" -eq 1 ]] && actions+=("unload via launchctl")
    [[ "${present}" -eq 1 ]] && actions+=("remove ${LAUNCHD_GRANOLA_DST}")
    [[ "${lock}" -eq 1 ]] && actions+=("clear stale lock dir")
    join_actions "${actions[@]}"
  fi
}

refactor_daily_status() {
  if [[ "${KEEP_REFACTOR_DAILY}" -eq 1 ]]; then
    echo "skipped (--keep-refactor-daily)"
    return
  fi
  local present=0 loaded=0 lock=0 legacy=0
  [[ -f "${LAUNCHD_REFACTOR_DST}" ]] && present=1
  if launchctl list 2>/dev/null | grep -q "${LAUNCHD_REFACTOR_LABEL}"; then loaded=1; fi
  [[ -f "${LEGACY_REFACTOR_DST}" ]] && legacy=1
  if launchctl list 2>/dev/null | grep -q "${LEGACY_REFACTOR_LABEL}"; then legacy=1; fi
  [[ -d "${REFACTOR_LOCK_DIR}" ]] && lock=1
  if [[ "${present}" -eq 0 && "${loaded}" -eq 0 && "${lock}" -eq 0 && "${legacy}" -eq 0 ]]; then
    echo "absent"
  else
    local actions=()
    [[ "${loaded}" -eq 1 ]] && actions+=("unload via launchctl")
    [[ "${present}" -eq 1 ]] && actions+=("remove ${LAUNCHD_REFACTOR_DST}")
    [[ "${legacy}" -eq 1 ]] && actions+=("remove legacy refactor-weekly plist")
    [[ "${lock}" -eq 1 ]] && actions+=("clear stale lock dir")
    join_actions "${actions[@]}"
  fi
}

legacy_cleanup_status() {
  local found=()
  [[ -L "${LEGACY_HOOK_DST}" || -e "${LEGACY_HOOK_DST}" ]] && found+=("${LEGACY_HOOK_DST}")
  [[ -L "${LEGACY_UPDATER_DST}" || -e "${LEGACY_UPDATER_DST}" ]] && found+=("${LEGACY_UPDATER_DST}")
  if [[ "${#found[@]}" -eq 0 ]]; then
    echo "clean"
  else
    echo "will remove: ${found[*]}"
  fi
}

# --- Print plan ---
cat <<EOF
Work-wiki uninstaller — planned actions

This removes ONLY the configuration and background processes that hook
the wiki into Claude Code and Codex. The wiki itself — your content and history —
stays untouched.

  Removed:
    SessionEnd hook symlink  : $(hook_status)
    Legacy hook artifacts    : $(legacy_cleanup_status)
    Settings file            : $(settings_status)
    Global CLAUDE.md         : $(claude_md_status)
    Codex config             : $(codex_config_status)
    Daily launchd plist      : $(daily_status)
    Slack daily plist        : $(slack_daily_status)
    Granola daily plist      : $(granola_daily_status)
    Codex ingest plist       : $(codex_ingest_status)
    Refactor daily plist     : $(refactor_daily_status)

  Kept (no action):
    Wiki repo                : ${WORK_WIKI}
    Wiki content             : ${WORK_WIKI}/wiki/
    Git history              : ${WORK_WIKI}/.git
    Resume cursors / queue   : ${WORK_WIKI}/.system/state/
    Historical logs          : ${HOME}/.claude/logs/wiki-*.log

EOF

if [[ "${ASSUME_YES}" -ne 1 ]]; then
  if [[ ! -t 0 ]]; then
    echo "Non-interactive shell — pass --yes to confirm." >&2
    exit 1
  fi
  read -r -p "Proceed? [y/N] " ans
  case "${ans}" in
    [Yy]|[Yy][Ee][Ss]) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

echo ""
echo "Uninstalling..."

# --- Hook symlink ---
if [[ -L "${HOOK_END_DST}" || -e "${HOOK_END_DST}" ]]; then
  rm -f "${HOOK_END_DST}"
  echo "✓ Removed ${HOOK_END_DST}"
fi
for stale in "${LEGACY_HOOK_DST}" "${LEGACY_UPDATER_DST}"; do
  if [[ -L "${stale}" || -e "${stale}" ]]; then
    rm -f "${stale}"
    echo "✓ Removed legacy ${stale}"
  fi
done

# --- Settings.json: strip SessionEnd entry and env keys (only when something to strip) ---
if [[ -f "${SETTINGS}" ]]; then
  if jq -e '.hooks.SessionEnd[]?.hooks[]? | select(.command? | tostring | test("wiki-session-end\\.sh|knowledge-session-end\\.sh"))' "${SETTINGS}" > /dev/null 2>&1; then
    TMP="$(mktemp)"
    jq '
      if .hooks.SessionEnd then
        .hooks.SessionEnd = (
          [ .hooks.SessionEnd[]
            | (.hooks // []) as $orig_hooks
            | .hooks = ([ $orig_hooks[] | select((.command? | tostring) | test("wiki-session-end\\.sh|knowledge-session-end\\.sh") | not) ])
            | select(.hooks | length > 0)
          ]
        )
        | if (.hooks.SessionEnd | length) == 0 then del(.hooks.SessionEnd) else . end
      else . end
      | if .hooks == {} then del(.hooks) else . end
    ' "${SETTINGS}" > "${TMP}" && mv "${TMP}" "${SETTINGS}"
    echo "✓ Stripped wiki SessionEnd entry from ${SETTINGS}"
  fi

  if [[ "${KEEP_SETTINGS_ENV}" -ne 1 ]]; then
    if jq -e '(.env // {}) | to_entries | map(select(.key | startswith("WORK_WIKI_") or startswith("WORK_TRACKER_"))) | length > 0' "${SETTINGS}" > /dev/null 2>&1; then
      TMP="$(mktemp)"
      jq '
        if .env then
          .env |= with_entries(select((.key | startswith("WORK_WIKI_") or startswith("WORK_TRACKER_")) | not))
          | if (.env | length) == 0 then del(.env) else . end
        else . end
      ' "${SETTINGS}" > "${TMP}" && mv "${TMP}" "${SETTINGS}"
      echo "✓ Stripped WORK_WIKI_* / WORK_TRACKER_* env keys from ${SETTINGS}"
    fi
  fi
fi

# --- CLAUDE.md: remove the work-wiki block ---
if [[ -f "${CLAUDE_MD}" ]]; then
  for marker in "${NEW_MARKER}" "${OLD_MARKER}"; do
    if grep -qF "${marker}" "${CLAUDE_MD}"; then
      CLAUDE_MD_PATH="${CLAUDE_MD}" MARKER_VAR="${marker}" python3 <<'PYEOF'
import os, re
path = os.environ["CLAUDE_MD_PATH"]
marker = os.environ["MARKER_VAR"]
with open(path) as f:
    txt = f.read()
pattern = re.compile(r"\n## [^\n]*" + re.escape(marker) + r".*?(?=\n## |\Z)", re.DOTALL)
new_txt, _ = pattern.subn("", txt)
with open(path, "w") as f:
    f.write(new_txt.rstrip("\n") + "\n")
PYEOF
      echo "✓ Removed ${marker} block from ${CLAUDE_MD}"
    fi
  done
fi

# --- Codex config: remove only the work-wiki developer_instructions block ---
if [[ -f "${CODEX_CONFIG}" && "$(grep -cF "${NEW_MARKER}" "${CODEX_CONFIG}" || true)" -gt 0 ]]; then
  python3 "${SCRIPT_DIR}/scripts/codex-config-instructions.py" uninstall \
    --config "${CODEX_CONFIG}" \
    --marker "${NEW_MARKER}"
  echo "✓ Removed ${NEW_MARKER} block from ${CODEX_CONFIG}"
fi

# --- Daily launchd plist ---
if [[ "${KEEP_DAILY}" -ne 1 ]]; then
  if launchctl list 2>/dev/null | grep -q "${LAUNCHD_LABEL}"; then
    launchctl unload -w "${LAUNCHD_DST}" 2>/dev/null && echo "✓ Unloaded ${LAUNCHD_LABEL}" || echo "WARN: launchctl unload failed (continuing)"
  fi
  if [[ -f "${LAUNCHD_DST}" ]]; then
    rm -f "${LAUNCHD_DST}"
    echo "✓ Removed ${LAUNCHD_DST}"
  fi
fi

# --- Slack daily launchd plist ---
if [[ "${KEEP_SLACK_DAILY}" -ne 1 ]]; then
  if launchctl list 2>/dev/null | grep -q "${LAUNCHD_SLACK_LABEL}"; then
    launchctl unload -w "${LAUNCHD_SLACK_DST}" 2>/dev/null && echo "✓ Unloaded ${LAUNCHD_SLACK_LABEL}" || echo "WARN: launchctl unload failed (continuing)"
  fi
  if [[ -f "${LAUNCHD_SLACK_DST}" ]]; then
    rm -f "${LAUNCHD_SLACK_DST}"
    echo "✓ Removed ${LAUNCHD_SLACK_DST}"
  fi
  if [[ -d "${SLACK_LOCK_DIR}" ]]; then
    rmdir "${SLACK_LOCK_DIR}" 2>/dev/null && echo "✓ Cleared stale Slack-ingest lock dir" || true
  fi
fi

# --- Granola daily launchd plist ---
if [[ "${KEEP_GRANOLA_DAILY}" -ne 1 ]]; then
  if launchctl list 2>/dev/null | grep -q "${LAUNCHD_GRANOLA_LABEL}"; then
    launchctl unload -w "${LAUNCHD_GRANOLA_DST}" 2>/dev/null && echo "✓ Unloaded ${LAUNCHD_GRANOLA_LABEL}" || echo "WARN: launchctl unload failed (continuing)"
  fi
  if [[ -f "${LAUNCHD_GRANOLA_DST}" ]]; then
    rm -f "${LAUNCHD_GRANOLA_DST}"
    echo "✓ Removed ${LAUNCHD_GRANOLA_DST}"
  fi
  if [[ -d "${GRANOLA_LOCK_DIR}" ]]; then
    rmdir "${GRANOLA_LOCK_DIR}" 2>/dev/null && echo "✓ Cleared stale Granola-ingest lock dir" || true
  fi
fi

# --- Codex ingest launchd plist ---
if [[ "${KEEP_CODEX_INGEST}" -ne 1 ]]; then
  if launchctl list 2>/dev/null | grep -q "${LAUNCHD_CODEX_LABEL}"; then
    launchctl unload -w "${LAUNCHD_CODEX_DST}" 2>/dev/null && echo "✓ Unloaded ${LAUNCHD_CODEX_LABEL}" || echo "WARN: launchctl unload failed (continuing)"
  fi
  if [[ -f "${LAUNCHD_CODEX_DST}" ]]; then
    rm -f "${LAUNCHD_CODEX_DST}"
    echo "✓ Removed ${LAUNCHD_CODEX_DST}"
  fi
fi

# --- Refactor daily launchd plist (and any legacy refactor-weekly artifacts) ---
if [[ "${KEEP_REFACTOR_DAILY}" -ne 1 ]]; then
  if launchctl list 2>/dev/null | grep -q "${LAUNCHD_REFACTOR_LABEL}"; then
    launchctl unload -w "${LAUNCHD_REFACTOR_DST}" 2>/dev/null && echo "✓ Unloaded ${LAUNCHD_REFACTOR_LABEL}" || echo "WARN: launchctl unload failed (continuing)"
  fi
  if [[ -f "${LAUNCHD_REFACTOR_DST}" ]]; then
    rm -f "${LAUNCHD_REFACTOR_DST}"
    echo "✓ Removed ${LAUNCHD_REFACTOR_DST}"
  fi
  if launchctl list 2>/dev/null | grep -q "${LEGACY_REFACTOR_LABEL}"; then
    launchctl unload -w "${LEGACY_REFACTOR_DST}" 2>/dev/null && echo "✓ Unloaded legacy ${LEGACY_REFACTOR_LABEL}" || echo "WARN: legacy launchctl unload failed (continuing)"
  fi
  if [[ -f "${LEGACY_REFACTOR_DST}" ]]; then
    rm -f "${LEGACY_REFACTOR_DST}"
    echo "✓ Removed legacy ${LEGACY_REFACTOR_DST}"
  fi
  if [[ -d "${REFACTOR_LOCK_DIR}" ]]; then
    rmdir "${REFACTOR_LOCK_DIR}" 2>/dev/null && echo "✓ Cleared stale refactor-review lock dir" || true
  fi
fi

echo ""
echo "Uninstall complete. The wiki at ${WORK_WIKI} is unchanged — read it,"
echo "version it, or re-install later by re-running .system/install.sh."
