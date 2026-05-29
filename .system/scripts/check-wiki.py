#!/usr/bin/env python3
"""Deterministic local checks for the work-wiki repository.

This is intentionally cheap and non-LLM-based. It catches structural drift
that should fail fast locally: script syntax, required wiki frontmatter,
broken relative markdown links, oversized Recent-activity bullets, and
Obsidian-style wikilinks.
"""
from __future__ import annotations

import re
import subprocess
import sys
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WIKI_DIR = ROOT / "wiki"

REQUIRED_FRONTMATTER_KEYS = ("type", "slug", "created", "updated", "sources")
WIKI_README_SLUG = "wiki-readme"
ALLOWED_SOURCE_KEYS = {
    "claude-transcripts",
    "codex-sessions",
    "slack-messages",
    "granola-notes",
    "lint-pass",
}
MAX_PAGE_LINES = 300

FRONTMATTER_RE = re.compile(r"\A---\n(?P<body>.*?)\n---\n", re.S)
LINK_RE = re.compile(r"(?<!!)\[[^\]\n]+\]\(([^)\n]+?\.md(?:#[^)]+)?)\)")
RECENT_HEADING_RE = re.compile(r"^##+\s+Recent activity\s*$")
DATED_BULLET_RE = re.compile(r"^- \d{4}-\d{2}-\d{2} — ")
WIKILINK_RE = re.compile(r"\[\[[^\]]+\]\]")
UPDATED_RE = re.compile(r"^updated:\s*(\d{4}-\d{2}-\d{2})\s*$", re.M)
SOURCE_RE = re.compile(r"^\s*-\s*([A-Za-z0-9_-]+):", re.M)
PROJECT_LINK_RE = re.compile(r"\]\(\.\./entities/projects/([^)#]+\.md)(?:#[^)]+)?\)")
OPEN_QUESTION_STATUS_RE = re.compile(r"^Status:\s+(open|resolved \d{4}-\d{2}-\d{2}|stale \d{4}-\d{2}-\d{2})\s*$")


def rel(path: Path) -> str:
    return str(path.relative_to(ROOT))


def issue(issues: list[str], path: Path, message: str, line: int | None = None) -> None:
    loc = rel(path)
    if line is not None:
        loc += f":{line}"
    issues.append(f"{loc}: {message}")


def mask_markdown_code(text: str) -> str:
    """Mask fenced and inline code so example links are not treated as links."""
    masked_lines: list[str] = []
    in_fence = False
    for line in text.splitlines(keepends=True):
        if line.lstrip().startswith("```"):
            in_fence = not in_fence
            masked_lines.append("\n" if line.endswith("\n") else "")
            continue
        if in_fence:
            masked_lines.append("\n" if line.endswith("\n") else "")
            continue
        masked_lines.append(re.sub(r"`[^`\n]*`", "", line))
    return "".join(masked_lines)


def check_shell_syntax(issues: list[str]) -> None:
    for script in sorted((ROOT / ".system").glob("**/*.sh")):
        result = subprocess.run(
            ["bash", "-n", str(script)],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )
        if result.returncode != 0:
            detail = (result.stderr or result.stdout).strip().splitlines()
            issue(issues, script, f"bash -n failed: {detail[0] if detail else 'syntax error'}")


def check_python_syntax(issues: list[str]) -> None:
    for script in sorted((ROOT / ".system" / "scripts").glob("*.py")):
        try:
            compile(script.read_text(), str(script), "exec")
        except SyntaxError as exc:
            detail = exc.msg
            if exc.lineno is not None:
                detail += f" at line {exc.lineno}"
            issue(issues, script, f"Python syntax check failed: {detail}")


def frontmatter_body(path: Path, text: str, issues: list[str]) -> str | None:
    match = FRONTMATTER_RE.match(text)
    if not match:
        issue(issues, path, "missing opening frontmatter block", 1)
        return None

    body = match.group("body")
    for key in REQUIRED_FRONTMATTER_KEYS:
        if not re.search(rf"^{re.escape(key)}:", body, flags=re.M):
            issue(issues, path, f"frontmatter missing `{key}:`")
    return body


def check_slug(path: Path, fm: str, issues: list[str]) -> None:
    match = re.search(r"^slug:\s*(.+?)\s*$", fm, flags=re.M)
    if not match:
        return

    slug = match.group(1)
    expected = path.stem
    if path == WIKI_DIR / "README.md":
        expected = WIKI_README_SLUG
    if slug != expected:
        issue(issues, path, f"slug `{slug}` does not match expected `{expected}`")


def check_sources(path: Path, fm: str, issues: list[str]) -> None:
    sources_match = re.search(r"^sources:\n(?P<body>(?:\s+- .+\n?)+)", fm, flags=re.M)
    if not sources_match:
        return

    for source in SOURCE_RE.findall(sources_match.group("body")):
        if source not in ALLOWED_SOURCE_KEYS:
            issue(issues, path, f"unsupported source key `{source}`")


def updated_value(fm: str) -> str | None:
    match = UPDATED_RE.search(fm)
    return match.group(1) if match else None


def should_skip_link_targets(path: Path) -> bool:
    return path.parent == WIKI_DIR / "syntheses" and path.name.startswith("lint-")


def check_markdown_links(path: Path, text: str, issues: list[str]) -> None:
    if should_skip_link_targets(path):
        return

    masked = mask_markdown_code(text)
    for match in LINK_RE.finditer(masked):
        target = match.group(1).split("#", 1)[0]
        if re.match(r"^[a-z][a-z0-9+.-]*:", target):
            continue
        target_path = (path.parent / target).resolve()
        try:
            target_path.relative_to(ROOT)
        except ValueError:
            issue(issues, path, f"markdown link escapes repo: {target}", line_for_offset(masked, match.start()))
            continue
        if not target_path.exists():
            issue(issues, path, f"broken markdown link: {target}", line_for_offset(masked, match.start()))


def line_for_offset(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def check_recent_activity(path: Path, text: str, issues: list[str]) -> None:
    lines = text.splitlines()
    in_recent = False
    for idx, line in enumerate(lines, start=1):
        if RECENT_HEADING_RE.match(line):
            in_recent = True
            continue
        if in_recent and line.startswith("## "):
            in_recent = False
        if not in_recent:
            continue
        if not line.strip():
            continue
        if DATED_BULLET_RE.match(line):
            if len(line) > 200:
                issue(issues, path, f"Recent activity bullet is {len(line)} chars (> 200)", idx)
            continue
        issue(issues, path, "Recent activity contains a non-dated or multi-line entry", idx)


def check_by_date(path: Path, text: str, issues: list[str]) -> None:
    if path != WIKI_DIR / "index" / "by-date.md":
        return

    for idx, line in enumerate(text.splitlines(), start=1):
        if line.startswith("- ") and len(line) > 200:
            issue(issues, path, f"by-date bullet is {len(line)} chars (> 200)", idx)
        if re.match(r"^##\s+\d{4}-\d{2}\s+totals\s*$", line, flags=re.I):
            issue(issues, path, "by-date totals sections are not allowed", idx)


def check_page_length(path: Path, text: str, issues: list[str]) -> None:
    line_count = len(text.splitlines())
    if line_count > MAX_PAGE_LINES:
        issue(issues, path, f"page is {line_count} lines (> {MAX_PAGE_LINES})")


def check_open_question_statuses(path: Path, text: str, issues: list[str]) -> None:
    if path != WIKI_DIR / "syntheses" / "open-questions.md":
        return

    lines = text.splitlines()
    for idx, line in enumerate(lines, start=1):
        if not line.startswith("## "):
            continue
        next_content = next((candidate for candidate in lines[idx:] if candidate.strip()), "")
        if not OPEN_QUESTION_STATUS_RE.match(next_content):
            issue(issues, path, "open question is missing a lifecycle Status line", idx)


def check_wikilinks(path: Path, text: str, issues: list[str]) -> None:
    masked = mask_markdown_code(text)
    for match in WIKILINK_RE.finditer(masked):
        issue(issues, path, "Obsidian-style wikilink is not allowed", line_for_offset(masked, match.start()))


def dirty_wiki_files() -> set[Path]:
    result = subprocess.run(
        ["git", "diff", "--name-only"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        return set()
    return {(ROOT / line).resolve() for line in result.stdout.splitlines() if line.startswith("wiki/")}


def check_dirty_updated_dates(frontmatter_by_path: dict[Path, str], issues: list[str]) -> None:
    today = date.today().isoformat()
    for path in sorted(dirty_wiki_files()):
        fm = frontmatter_by_path.get(path)
        if fm is None:
            continue
        updated = updated_value(fm)
        if updated is not None and updated < today:
            issue(issues, path, f"`updated:` is {updated}, older than today ({today}) for a dirty file")


def check_project_index(issues: list[str]) -> None:
    by_project = WIKI_DIR / "index" / "by-project.md"
    if not by_project.exists():
        issue(issues, by_project, "missing project index")
        return

    text = by_project.read_text()
    linked = set(PROJECT_LINK_RE.findall(text))
    for project_path in sorted((WIKI_DIR / "entities" / "projects").glob("*.md")):
        rel_target = project_path.name
        if rel_target not in linked:
            issue(issues, by_project, f"missing project page link for `{rel(project_path)}`")


def check_wiki_markdown(issues: list[str]) -> None:
    frontmatter_by_path: dict[Path, str] = {}
    for path in sorted(WIKI_DIR.glob("**/*.md")):
        text = path.read_text()
        fm = frontmatter_body(path, text, issues)
        if fm is not None:
            frontmatter_by_path[path.resolve()] = fm
            check_slug(path, fm, issues)
            check_sources(path, fm, issues)
        check_markdown_links(path, text, issues)
        check_recent_activity(path, text, issues)
        check_by_date(path, text, issues)
        check_page_length(path, text, issues)
        check_open_question_statuses(path, text, issues)
        check_wikilinks(path, text, issues)
    check_dirty_updated_dates(frontmatter_by_path, issues)
    check_project_index(issues)


def main() -> int:
    issues: list[str] = []
    check_shell_syntax(issues)
    check_python_syntax(issues)
    check_wiki_markdown(issues)

    if issues:
        print(f"check-wiki: {len(issues)} issue(s) found")
        for item in issues:
            print(f"- {item}")
        return 1

    print("check-wiki: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
