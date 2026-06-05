#!/usr/bin/env python3
"""Deterministic, advisory checks for the worklog tree.

Cheap and non-LLM-based, mirroring check-wiki.py but scoped to `worklog/`.
Catches structural drift in the transient layer: required frontmatter on live
and archived workstreams, status values appropriate to live vs archive, slug /
filename agreement, board line format, board <-> live consistency, broken
relative links, and the per-item size cap.

Run manually: python3 .system/scripts/check-worklog.py
Exit 0 = ok, 1 = issues found.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKLOG_DIR = ROOT / "worklog"
LIVE_DIR = WORKLOG_DIR / "live"
ARCHIVE_DIR = WORKLOG_DIR / "archive"
BOARD = WORKLOG_DIR / "board.md"

REQUIRED_KEYS = ("type", "slug", "status", "created", "updated", "keys")
LIVE_STATUSES = {"active", "blocked", "waiting", "stale"}
ARCHIVE_STATUSES = {"merged", "closed", "done"}
MAX_LIVE_LINES = 80

FRONTMATTER_RE = re.compile(r"\A---\n(?P<body>.*?)\n---\n", re.S)
KEY_RE = re.compile(r"^([A-Za-z_]+):\s*(.*)$")
LINK_RE = re.compile(r"(?<!!)\[[^\]\n]+\]\(([^)\n]+?\.md(?:#[^)]+)?)\)")
# - [status] slug — next action ([detail](live/<slug>.md))
BOARD_LINE_RE = re.compile(r"^- \[[a-z-]+\]\s+\S.*\(live/([^)]+\.md)\)\s*$")


def rel(path: Path) -> str:
    return str(path.relative_to(ROOT))


def issue(issues: list[str], path: Path, message: str, line: int | None = None) -> None:
    loc = rel(path)
    if line is not None:
        loc += f":{line}"
    issues.append(f"{loc}: {message}")


def frontmatter(path: Path, text: str, issues: list[str]) -> dict | None:
    m = FRONTMATTER_RE.match(text)
    if not m:
        issue(issues, path, "missing or malformed frontmatter (--- block)")
        return None
    fm: dict[str, str] = {}
    for raw in m.group("body").splitlines():
        km = KEY_RE.match(raw)
        if km:
            fm[km.group(1)] = km.group(2).strip()
    return fm


def check_item(path: Path, allowed_statuses: set[str], is_live: bool, issues: list[str]) -> None:
    text = path.read_text()
    fm = frontmatter(path, text, issues)
    if fm is None:
        return
    for key in REQUIRED_KEYS:
        if key not in fm:
            issue(issues, path, f"missing required frontmatter key `{key}`")
    if fm.get("type") and fm["type"] != "workstream":
        issue(issues, path, f"type should be `workstream`, found `{fm['type']}`")
    slug = fm.get("slug", "")
    if slug and slug != path.stem:
        issue(issues, path, f"slug `{slug}` does not match filename `{path.stem}`")
    status = fm.get("status", "")
    if status and status not in allowed_statuses:
        where = "live" if is_live else "archive"
        issue(issues, path, f"status `{status}` not valid for {where} items {sorted(allowed_statuses)}")
    # relative link targets resolve
    for target in LINK_RE.findall(text):
        rel_target = target.split("#", 1)[0]
        if rel_target.startswith(("http://", "https://")):
            continue
        if not (path.parent / rel_target).resolve().exists():
            issue(issues, path, f"broken relative link → `{target}`")
    if is_live:
        n = len(text.splitlines())
        if n > MAX_LIVE_LINES:
            issue(issues, path, f"live item is {n} lines, exceeds cap of {MAX_LIVE_LINES}")


def check_board(issues: list[str]) -> None:
    if not BOARD.exists():
        issue(issues, BOARD, "missing worklog board")
        return
    text = BOARD.read_text()
    referenced: set[str] = set()
    for i, line in enumerate(text.splitlines(), 1):
        if not line.startswith("- ["):
            continue
        m = BOARD_LINE_RE.match(line)
        if not m:
            issue(issues, BOARD, "board line does not match `- [status] <slug> — <next> (live/<slug>.md)`", i)
            continue
        ref = m.group(1)
        referenced.add(ref)
        if not (LIVE_DIR / ref).exists():
            issue(issues, BOARD, f"board references missing live item `live/{ref}`", i)
    # Every live item should have a board line.
    if LIVE_DIR.is_dir():
        for live in sorted(LIVE_DIR.glob("*.md")):
            if live.name not in referenced:
                issue(issues, BOARD, f"no board line for live item `{rel(live)}`")


def main() -> int:
    issues: list[str] = []
    if not WORKLOG_DIR.is_dir():
        print("check-worklog: no worklog/ directory — nothing to check")
        return 0
    if LIVE_DIR.is_dir():
        for path in sorted(LIVE_DIR.glob("*.md")):
            check_item(path, LIVE_STATUSES, is_live=True, issues=issues)
    if ARCHIVE_DIR.is_dir():
        for path in sorted(ARCHIVE_DIR.glob("*.md")):
            check_item(path, ARCHIVE_STATUSES, is_live=False, issues=issues)
    check_board(issues)

    if issues:
        print(f"check-worklog: {len(issues)} issue(s) found")
        for item in issues:
            print(f"- {item}")
        return 1
    print("check-worklog: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
