#!/usr/bin/env python3
"""Install or remove the Work Wiki block in Codex config.toml.

Codex reads `developer_instructions` as a top-level TOML key. If that key is
appended after a `[table]` header, TOML treats it as a member of that table.
This helper keeps the key at top level and repairs previously misplaced
Work Wiki blocks.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import tomllib
from pathlib import Path


Assignment = tuple[int, int, str, bool]


def find_assignments(text: str) -> list[Assignment]:
    lines = text.splitlines(keepends=True)
    assignments: list[Assignment] = []
    offset = 0
    in_top_level = True

    for i, line in enumerate(lines):
        if re.match(r"^\s*\[[^\]]+\]\s*(?:#.*)?$", line):
            in_top_level = False

        match = re.match(r"^developer_instructions\s*=", line)
        if not match:
            offset += len(line)
            continue

        rhs = line.split("=", 1)[1].lstrip()
        end_line = i + 1
        token = None
        if rhs.startswith('"""'):
            token = '"""'
        elif rhs.startswith("'''"):
            token = "'''"

        if token is not None:
            rest = rhs[len(token) :]
            if token not in rest:
                for j in range(i + 1, len(lines)):
                    end_line = j + 1
                    if token in lines[j]:
                        break

        end = sum(len(part) for part in lines[:end_line])
        assignments.append((offset, end, text[offset:end], in_top_level))
        offset += len(line)

    return assignments


def parse_assignment(raw: str) -> str:
    return tomllib.loads(raw).get("developer_instructions", "")


def strip_block(value: str, marker: str) -> str:
    pattern = re.compile(
        r"\n?## [^\n]*" + re.escape(marker) + r".*?(?=\n## |\Z)",
        re.DOTALL,
    )
    return pattern.sub("", value).strip()


def line_for(value: str) -> str:
    return "developer_instructions = " + json.dumps(value) + "\n"


def remove_ranges(text: str, ranges: list[tuple[int, int]]) -> str:
    for start, end in sorted(ranges, reverse=True):
        text = text[:start] + text[end:]
    return text


def insert_top_level(text: str, assignment: str) -> str:
    stripped = text.lstrip()
    leading_len = len(text) - len(stripped)
    if stripped.startswith("#"):
        lines = text.splitlines(keepends=True)
        offset = 0
        insert_at = 0
        for line in lines:
            if line.startswith("#") or line.strip() == "":
                offset += len(line)
                insert_at = offset
                continue
            break
        return text[:insert_at] + assignment + "\n" + text[insert_at:]
    return text[:leading_len] + assignment + ("\n" if stripped else "") + text[leading_len:]


def install(config: Path, block: str, marker: str) -> None:
    text = config.read_text() if config.exists() else ""
    assignments = find_assignments(text)

    top_level: Assignment | None = next((a for a in assignments if a[3]), None)
    misplaced_work_wiki_ranges: list[tuple[int, int]] = []
    base = ""

    for start, end, raw, is_top_level in assignments:
        try:
            value = parse_assignment(raw)
        except Exception:
            value = ""

        if is_top_level and (start, end, raw, is_top_level) == top_level:
            base = strip_block(value, marker)
        elif marker in value:
            misplaced_work_wiki_ranges.append((start, end))

    new_value = (base.rstrip() + "\n\n" + block.strip()) if base else block.strip()
    replacement = line_for(new_value)

    if top_level is not None:
        start, end, _raw, _is_top_level = top_level
        text = text[:start] + replacement + text[end:]

    text = remove_ranges(text, misplaced_work_wiki_ranges)

    if top_level is None:
        text = insert_top_level(text.rstrip("\n"), replacement)

    config.parent.mkdir(parents=True, exist_ok=True)
    config.write_text(text.rstrip("\n") + "\n")


def uninstall(config: Path, marker: str) -> None:
    if not config.exists():
        return

    text = config.read_text()
    assignments = find_assignments(text)
    replacements: list[tuple[int, int, str]] = []

    for start, end, raw, _is_top_level in assignments:
        try:
            value = parse_assignment(raw)
        except Exception:
            continue
        if marker not in value:
            continue
        cleaned = strip_block(value, marker)
        replacement = line_for(cleaned) if cleaned else ""
        replacements.append((start, end, replacement))

    for start, end, replacement in sorted(replacements, reverse=True):
        text = text[:start] + replacement + text[end:]

    config.write_text(text.rstrip("\n") + "\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("install", "uninstall"))
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--marker", required=True)
    parser.add_argument("--block")
    args = parser.parse_args()

    if args.action == "install":
        if args.block is None:
            parser.error("--block is required for install")
        install(args.config, args.block, args.marker)
    else:
        uninstall(args.config, args.marker)
    return 0


if __name__ == "__main__":
    sys.exit(main())
