#!/usr/bin/env python3
"""Detect and compress over-budget bullets in Recent-activity sections.

Usage:
  compress-recent-activity.py [--char-limit N] [--json] [--compress] [--limit N] [PATH ...]

Default mode is detect-only: prints over-budget bullets sorted by char count.
Pass --compress to rewrite them in place via the configured headless provider, preserving the
date prefix and all markdown links (PRs, exec plans, ticket IDs).

What "over-budget" means:
  SCHEMA.md requires each Recent-activity bullet to be one line, <=200
  characters. Bullets exceeding the limit are flagged. The "- " markdown
  marker is not counted toward the limit.

What it does NOT do:
  - Touch bullets outside `## Recent activity` sections.
  - Compress deterministically (e.g. truncate). Truncation drops links;
    LLM rewriting preserves them by design.
  - Re-flow paragraphs elsewhere on the page. Out of scope.
"""
from __future__ import annotations

import argparse
import json
import re
import os
import subprocess
import sys
from collections import defaultdict
from datetime import date
from pathlib import Path

CHAR_LIMIT = 200
BULLET_RE = re.compile(r"^- (\d{4}-\d{2}-\d{2}) — ")
SECTION_RE = re.compile(r"^##+\s+Recent activity\s*$")
ANY_HEADING_RE = re.compile(r"^##+\s")


def wiki_root() -> Path:
    return Path(__file__).resolve().parents[2]


def runner_path() -> Path:
    return wiki_root() / ".system/scripts/headless-agent-run.sh"


def find_recent_activity_spans(lines: list[str]) -> list[tuple[int, int]]:
    """Return [start, end) line indices for each Recent-activity section body."""
    spans: list[tuple[int, int]] = []
    for i, line in enumerate(lines):
        if SECTION_RE.match(line):
            end = len(lines)
            for j in range(i + 1, len(lines)):
                if ANY_HEADING_RE.match(lines[j]):
                    end = j
                    break
            spans.append((i + 1, end))
    return spans


def iter_bullets(lines: list[str], start: int, end: int):
    """Yield (start_line, end_line_exclusive, text) for each bullet in [start, end)."""
    i = start
    while i < end:
        if BULLET_RE.match(lines[i]):
            j = i + 1
            while (
                j < end
                and not BULLET_RE.match(lines[j])
                and not ANY_HEADING_RE.match(lines[j])
                and lines[j].strip()
            ):
                j += 1
            text = "\n".join(lines[i:j])
            yield (i, j, text)
            i = j
        else:
            i += 1


def measure(text: str) -> tuple[int, int]:
    body = text[2:] if text.startswith("- ") else text
    return len(body), len(body.split())


def scan_page(path: Path, char_limit: int) -> list[dict]:
    lines = path.read_text().splitlines()
    out: list[dict] = []
    for sec_start, sec_end in find_recent_activity_spans(lines):
        for line_idx, end_idx, text in iter_bullets(lines, sec_start, sec_end):
            chars, words = measure(text)
            if chars > char_limit:
                out.append(
                    {
                        "path": str(path),
                        "line": line_idx + 1,
                        "end_line_exclusive": end_idx,
                        "chars": chars,
                        "words": words,
                        "text": text,
                    }
                )
    return out


COMPRESS_PROMPT = """Rewrite this wiki Recent-activity bullet to <= {limit} characters on a single line.

Rules:
- Keep the leading `- YYYY-MM-DD — ` prefix exactly as written.
- Keep every markdown link `[text](path)` intact. Links are pointers to source-of-truth docs (exec plans, PRs, RCAs, Notion); they are not paraphrasable prose.
- Drop summary prose. The bullet should point to the docs, not duplicate their contents.
- One line. No embedded newlines. No code fences. No commentary.
- Output ONLY the rewritten bullet line. The first character of your response must be `-`.

Original:
{text}
"""


def compress_one(text: str, char_limit: int) -> str | None:
    prompt = COMPRESS_PROMPT.format(limit=char_limit, text=text)
    try:
        result = subprocess.run(
            [
                str(runner_path()),
                "--job",
                "compress",
                "--stdin",
                "--allowed-claude-tools",
                "",
                "--codex-writable-dir",
                str(wiki_root()),
                "--log-label",
                "recent-activity-compress",
            ],
            input=prompt,
            capture_output=True,
            text=True,
            check=True,
            timeout=120,
            env={**os.environ, "WORK_WIKI": str(wiki_root())},
        )
    except FileNotFoundError:
        sys.exit("ERROR: headless runner not found")
    except subprocess.CalledProcessError as e:
        print(f"  WARN: headless provider failed: {e.stderr.strip()[:200]}", file=sys.stderr)
        return None
    except subprocess.TimeoutExpired:
        print("  WARN: headless provider timed out", file=sys.stderr)
        return None

    out = result.stdout.strip()
    # Strip any accidental code-fence wrapping.
    if out.startswith("```"):
        out = out.strip("`").lstrip("markdown").lstrip("md").strip()
    # Take only the first non-empty line.
    for line in out.splitlines():
        if line.strip():
            out = line.rstrip()
            break
    if not out.startswith("- ") or not BULLET_RE.match(out):
        print(f"  WARN: rewrite did not produce a valid bullet, skipping: {out[:80]!r}", file=sys.stderr)
        return None
    new_chars, _ = measure(out)
    orig_chars, _ = measure(text)
    if new_chars >= orig_chars:
        print(f"  WARN: rewrite no shorter ({new_chars} >= {orig_chars}), skipping", file=sys.stderr)
        return None
    if new_chars > char_limit:
        print(f"  NOTE: accepted shorter rewrite still over budget ({new_chars} > {char_limit})", file=sys.stderr)
    return out


def bump_updated(text: str) -> str:
    today = date.today().isoformat()
    if not text.startswith("---\n"):
        return text
    end = text.find("\n---\n", 4)
    if end == -1:
        return text
    fm = text[4:end]
    body = text[end + 5:]
    new_fm, n = re.subn(r"^updated:\s*.*$", f"updated: {today}", fm, count=1, flags=re.M)
    if n == 0:
        return text
    return "---\n" + new_fm + "\n---\n" + body


def main() -> None:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--char-limit", type=int, default=CHAR_LIMIT)
    ap.add_argument("--json", action="store_true", help="emit JSON instead of text")
    ap.add_argument(
        "--compress",
        action="store_true",
        help="rewrite over-budget bullets in place via the configured headless provider",
    )
    ap.add_argument(
        "--limit",
        type=int,
        default=None,
        help="when --compress, only rewrite the N worst bullets",
    )
    ap.add_argument(
        "paths",
        nargs="*",
        type=Path,
        help="specific pages to scan (default: all wiki/**/*.md)",
    )
    args = ap.parse_args()

    root = wiki_root()
    targets = args.paths or sorted(root.glob("wiki/**/*.md"))
    findings: list[dict] = []
    for p in targets:
        findings.extend(scan_page(p, args.char_limit))

    findings.sort(key=lambda f: f["chars"], reverse=True)

    if args.json:
        print(json.dumps(findings, indent=2))
    else:
        if not findings:
            print(f"No bullets over {args.char_limit} chars.")
            return
        rel = lambda p: Path(p).relative_to(root) if Path(p).is_absolute() else Path(p)
        for f in findings:
            preview = f["text"].splitlines()[0]
            if len(preview) > 100:
                preview = preview[:100] + "..."
            print(f"{rel(f['path'])}:{f['line']}  {f['chars']} chars  {f['words']} words")
            print(f"  {preview}")
        print()
        print(f"Total over-budget bullets: {len(findings)} (limit {args.char_limit} chars)")

    if not args.compress:
        return

    to_compress = findings[: args.limit] if args.limit else findings
    if not to_compress:
        return

    print(f"\nCompressing {len(to_compress)} bullet(s)...", file=sys.stderr)

    by_page: dict[str, list[dict]] = defaultdict(list)
    for f in to_compress:
        by_page[f["path"]].append(f)

    total_rewritten = 0
    total_skipped = 0
    for path_str, page_findings in by_page.items():
        page_findings.sort(key=lambda f: f["line"], reverse=True)
        p = Path(path_str)
        original = p.read_text()
        lines = original.splitlines()
        page_rewrote = 0
        for f in page_findings:
            rewritten = compress_one(f["text"], args.char_limit)
            if rewritten is None:
                total_skipped += 1
                continue
            lines[f["line"] - 1 : f["end_line_exclusive"]] = [rewritten]
            page_rewrote += 1
            total_rewritten += 1
            p_disp = Path(path_str)
            if p_disp.is_absolute():
                try:
                    p_disp = p_disp.relative_to(root)
                except ValueError:
                    pass
            print(f"  rewrote {p_disp}:{f['line']}", file=sys.stderr)
        if page_rewrote:
            new_text = "\n".join(lines) + "\n"
            new_text = bump_updated(new_text)
            p.write_text(new_text)

    print(
        f"\nDone. Rewrote {total_rewritten}, skipped {total_skipped}.",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
