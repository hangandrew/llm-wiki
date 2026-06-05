#!/usr/bin/env bash
# Sync the .system/ tooling tree from the upstream public template repo.
#
# The public llm-wiki repo is the source of truth for installer/automation code.
# A downstream instance (e.g. a private work-wiki with real wiki/ + worklog/
# content) runs this to pull tooling updates WITHOUT touching its private data.
#
# SAFETY MODEL
#   - Only files under .system/ are ever modified. Your wiki/ and worklog/ are
#     never touched, so private content cannot be overwritten.
#   - .system/state/ is gitignored, so local cursors/queue are left alone.
#   - Data flows upstream -> here only. This script never pushes to upstream.
#   - A staged-path guard aborts if anything outside .system/ would be committed.
#
# USAGE
#   sync-system.sh [--dry-run] [--no-commit]
#     --dry-run    Show the .system/ changes that would be applied; change nothing.
#     --no-commit  Apply + stage the changes but leave the commit to you.
#
# ENV
#   WORK_WIKI_UPSTREAM_REMOTE   remote to pull from (default: upstream)
#   WORK_WIKI_UPSTREAM_BRANCH   branch to pull      (default: main)

set -euo pipefail

# Re-exec from a stable copy so that updating THIS script mid-sync is safe
# (git checkout below may rewrite sync-system.sh itself). REPO is resolved before
# re-exec and passed through, since $0 then points at the temp copy.
if [[ "${_SYNC_REEXEC:-}" != "1" ]]; then
  _self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  _repo="$(cd "$(dirname "${_self}")/../.." && pwd)"
  _tmp="$(mktemp "${TMPDIR:-/tmp}/sync-system.XXXXXX")"
  cat "${_self}" > "${_tmp}"
  _SYNC_REEXEC=1 _SYNC_REPO="${_repo}" exec bash "${_tmp}" "$@"
fi
# From here we run inside the temp copy; clean it up on exit.
trap 'rm -f "${BASH_SOURCE[0]}" 2>/dev/null || true' EXIT

REMOTE="${WORK_WIKI_UPSTREAM_REMOTE:-upstream}"
BRANCH="${WORK_WIKI_UPSTREAM_BRANCH:-main}"
DRY_RUN=0
DO_COMMIT=1
for arg in "$@"; do
  case "${arg}" in
    --dry-run)   DRY_RUN=1 ;;
    --no-commit) DO_COMMIT=0 ;;
    -h|--help)   sed -n '2,24p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)           echo "Unknown argument: ${arg}" >&2; exit 2 ;;
  esac
done

REPO="${_SYNC_REPO}"
cd "${REPO}"

git rev-parse --git-dir >/dev/null 2>&1 || { echo "ERROR: not a git repo: ${REPO}" >&2; exit 1; }

if ! git remote get-url "${REMOTE}" >/dev/null 2>&1; then
  echo "ERROR: remote '${REMOTE}' is not configured." >&2
  echo "  Add the public template as upstream, e.g.:" >&2
  echo "    git remote add ${REMOTE} git@github.com:hangandrew/llm-wiki.git" >&2
  exit 1
fi

echo "Fetching ${REMOTE}/${BRANCH}…"
git fetch --quiet "${REMOTE}" "${BRANCH}"
REF="${REMOTE}/${BRANCH}"
UPSTREAM_SHA="$(git rev-parse --short "${REF}")"

CHANGES="$(git diff --name-status HEAD "${REF}" -- .system/ || true)"
if [[ -z "${CHANGES}" ]]; then
  echo "Already in sync with ${REF} (@ ${UPSTREAM_SHA}). Nothing to do."
  exit 0
fi

echo "Changes under .system/ (HEAD → ${REF} @ ${UPSTREAM_SHA}):"
echo "${CHANGES}" | sed 's/^/  /'

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "(dry run — nothing modified)"
  exit 0
fi

# Apply: add/modify from upstream…
git checkout "${REF}" -- .system/
# …then delete files that exist in our .system/ but were removed upstream.
comm -23 \
  <(git ls-tree -r --name-only HEAD          -- .system/ | sort) \
  <(git ls-tree -r --name-only "${REF}"      -- .system/ | sort) \
  | while IFS= read -r f; do
      [[ -n "${f}" ]] && git rm -q -- "${f}" || true
    done

# Safety net: refuse to proceed if anything outside .system/ got staged.
OUTSIDE="$(git diff --cached --name-only | grep -v '^\.system/' || true)"
if [[ -n "${OUTSIDE}" ]]; then
  echo "ABORT: changes staged outside .system/ — refusing to continue:" >&2
  echo "${OUTSIDE}" | sed 's/^/  /' >&2
  echo "Undo with: git restore --staged --worktree ." >&2
  exit 3
fi

if git diff --cached --quiet; then
  echo "Working tree already matched ${REF}; nothing to commit."
  exit 0
fi

if [[ "${DO_COMMIT}" -eq 0 ]]; then
  echo "Staged .system/ updates (--no-commit). Review with 'git diff --cached', then commit."
  exit 0
fi

git commit -q -m "sync: .system/ from ${REMOTE}/${BRANCH} @ ${UPSTREAM_SHA}"
echo "Committed .system/ sync from ${REMOTE}/${BRANCH} @ ${UPSTREAM_SHA}."
echo "(push when ready — this script never pushes.)"
