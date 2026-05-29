#!/usr/bin/env bash
# Advisory detectors for the synthesizer to invoke after headless provider runs.
#
# Emits zero or more lines to stdout — caller (wiki-synthesizer.sh) pipes
# each line through its own `log` function. Never writes to wiki/. Never
# exits nonzero on findings; only fails if the detectors themselves crash.
#
# Two passes:
#   1. Bullet verbosity — scoped to pages the synth modified in this run
#      (`git diff --name-only -- wiki/` against the unstaged working tree).
#   2. Synthesis rot — wiki-wide, since rot signals what synth FAILED to
#      touch, not what it just wrote.
#
# Both are pure-Python; no LLM call. See compress-recent-activity.py and
# detect-synthesis-rot.py for the underlying logic.
set -uo pipefail

WORK_WIKI="${WORK_WIKI:-${WORK_WIKI_DIR:-${HOME}/work-wiki}}"

format_bullets='
import json, sys
data = json.loads(sys.stdin.read() or "[]")
if not data:
    sys.exit()
print("WARN: {} over-budget Recent-activity bullet(s) on synth-touched pages (cap: 200 chars)".format(len(data)))
for f in data:
    print("  {path}:{line}  {chars}c  {words}w".format(**f))
'

format_rot='
import json, sys
data = json.loads(sys.stdin.read() or "[]")
if not data:
    sys.exit()
print("WARN: {} synthesis page(s) rotting (>= 7d behind linked entities)".format(len(data)))
for r in data:
    print("  {path}  updated {updated}  rot={max_delta_days}d  newer_links={newer_count}/{linked}".format(**r))
'

emit_bullet_warnings() {
  local touched
  touched=$(git -C "$WORK_WIKI" diff --name-only -- wiki/ 2>/dev/null | grep '\.md$' || true)
  [[ -z "$touched" ]] && return 0
  (cd "$WORK_WIKI" && echo "$touched" | xargs python3 .system/scripts/compress-recent-activity.py --json 2>/dev/null) \
    | python3 -c "$format_bullets" 2>/dev/null
}

emit_rot_warnings() {
  python3 "$WORK_WIKI/.system/scripts/detect-synthesis-rot.py" --json 2>/dev/null \
    | python3 -c "$format_rot" 2>/dev/null
}

emit_bullet_warnings
emit_rot_warnings
