#!/usr/bin/env bash
# Auto-compress over-budget Recent-activity bullets on pages the synthesizer
# modified in this run. Invoked by wiki-synthesizer.sh before the advisory
# detector, so rewrites fold into the same commit.
#
# Scopes via `git diff --name-only` against the unstaged working tree. Only
# touches *.md files under wiki/. If the working tree is clean, exits silently.
#
# Emits each line of compress-recent-activity.py output to stdout — caller
# pipes through its `log` function. Never exits non-zero on findings; only
# fails if the script crashes.
set -uo pipefail

WORK_WIKI="${WORK_WIKI:-${WORK_WIKI_DIR:-${HOME}/work-wiki}}"

touched=$(git -C "$WORK_WIKI" diff --name-only -- wiki/ 2>/dev/null | grep '\.md$' || true)
[[ -z "$touched" ]] && exit 0

cd "$WORK_WIKI" || exit 0
echo "$touched" | xargs python3 .system/scripts/compress-recent-activity.py --compress 2>&1
