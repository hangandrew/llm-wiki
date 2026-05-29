#!/usr/bin/env python3
"""Rename a wiki entity, preserving the prior slug as an alias and rewriting cross-links.

Usage:
  rename-entity.py --type {project|person|technology|concept} --old <slug> --new <slug> [--dry-run]

Default mode applies the rename. Pass --dry-run to preview without modifying anything.

What it does:
  1. Moves wiki/<dir>/<old>.md  ->  wiki/<dir>/<new>.md
  2. Rewrites frontmatter: slug, updated (today), aliases (appends <old>)
  3. Rewrites every markdown link across wiki/**/*.md that targets <old>.md
  4. Reports — but does not rewrite — bare prose mentions of <old>. Prose
     auto-rewrite is intentionally out of scope: "(formerly <old>)" and quoted
     historical context are legitimate uses and wrong replacement is silent.
"""
from __future__ import annotations

import argparse
import re
import sys
from datetime import date
from pathlib import Path

ENTITY_DIRS = {
    "project": "wiki/entities/projects",
    "person": "wiki/entities/people",
    "technology": "wiki/entities/technologies",
    "concept": "wiki/concepts",
}


def wiki_root() -> Path:
    return Path(__file__).resolve().parents[2]


def rewrite_frontmatter(text: str, old_slug: str, new_slug: str) -> str:
    today = date.today().isoformat()
    if not text.startswith("---\n"):
        sys.exit("ERROR: file missing opening --- frontmatter delimiter")
    end = text.find("\n---\n", 4)
    if end == -1:
        sys.exit("ERROR: file frontmatter not closed")
    fm = text[4:end]
    body = text[end + 5:]

    fm = re.sub(r"^slug:\s*.*$", f"slug: {new_slug}", fm, count=1, flags=re.M)
    fm = re.sub(r"^updated:\s*.*$", f"updated: {today}", fm, count=1, flags=re.M)

    alias_match = re.search(r"^aliases:[ \t]*(.*)$", fm, flags=re.M)
    if alias_match:
        existing = alias_match.group(1).strip()
        if existing.startswith("[") and existing.endswith("]"):
            inner = existing[1:-1].strip()
            current = [s.strip() for s in inner.split(",") if s.strip()]
            if old_slug not in current:
                current.append(old_slug)
            replacement = f"aliases: [{', '.join(current)}]"
            fm = re.sub(r"^aliases:[ \t]*.*$", replacement, fm, count=1, flags=re.M)
        elif existing == "":
            block_pat = re.compile(r"^(aliases:\s*\n)((?:  - .*\n)*)", re.M)
            m = block_pat.search(fm)
            if m and f"  - {old_slug}\n" not in m.group(2):
                insert_at = m.end(2)
                fm = fm[:insert_at] + f"  - {old_slug}\n" + fm[insert_at:]
        else:
            sys.exit(f"ERROR: unrecognized aliases format: {existing!r}")
    else:
        fm = re.sub(
            r"^(slug:.*)$",
            rf"\1\naliases: [{old_slug}]",
            fm,
            count=1,
            flags=re.M,
        )

    return "---\n" + fm + "\n---\n" + body


def link_pattern(slug: str) -> re.Pattern[str]:
    # Matches `](...<slug>.md)` or `](...<slug>.md#anchor)` inside a markdown link.
    return re.compile(
        rf"(\]\()([^)]*?){re.escape(slug)}(\.md(?:#[^)]*)?\))"
    )


def rewrite_links_in(text: str, old_slug: str, new_slug: str) -> tuple[str, int]:
    pat = link_pattern(old_slug)

    def repl(m: re.Match[str]) -> str:
        prefix = m.group(2)
        if "://" in prefix:
            return m.group(0)
        return f"{m.group(1)}{prefix}{new_slug}{m.group(3)}"

    new_text, n = pat.subn(repl, text)
    return new_text, n


def count_links_in(text: str, slug: str) -> int:
    pat = link_pattern(slug)
    return sum(1 for m in pat.finditer(text) if "://" not in m.group(2))


def find_prose_mentions(text: str, slug: str, old_path_basename: str) -> list[int]:
    """Return line numbers where the bare slug appears outside a markdown link path."""
    link_pat = link_pattern(slug)
    # First, mask out link targets so we don't re-flag them.
    masked = link_pat.sub(lambda m: "\x00" * len(m.group(0)), text)
    # Also mask the frontmatter slug/aliases lines so we don't flag those.
    word_pat = re.compile(rf"\b{re.escape(slug)}\b")
    lines: list[int] = []
    for i, line in enumerate(masked.splitlines(), start=1):
        stripped = line.lstrip()
        if stripped.startswith(("slug:", "aliases:", "- ")) and slug in line:
            continue
        if word_pat.search(line):
            lines.append(i)
    return lines


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--type", required=True, choices=sorted(ENTITY_DIRS.keys()))
    ap.add_argument("--old", required=True, help="current slug")
    ap.add_argument("--new", required=True, help="new slug")
    ap.add_argument("--dry-run", action="store_true", help="preview without modifying anything")
    args = ap.parse_args()

    root = wiki_root()
    entity_dir = root / ENTITY_DIRS[args.type]
    old_path = entity_dir / f"{args.old}.md"
    new_path = entity_dir / f"{args.new}.md"

    if not old_path.exists():
        sys.exit(f"ERROR: {old_path.relative_to(root)} does not exist")
    if new_path.exists():
        sys.exit(f"ERROR: {new_path.relative_to(root)} already exists")
    if args.old == args.new:
        sys.exit("ERROR: --old and --new are the same")

    old_text = old_path.read_text()
    new_fm_text = rewrite_frontmatter(old_text, args.old, args.new)

    link_targets: list[tuple[Path, int]] = []
    prose_targets: list[tuple[Path, list[int]]] = []
    for md in sorted(root.glob("wiki/**/*.md")):
        if md == old_path:
            continue
        body = md.read_text()
        n_links = count_links_in(body, args.old)
        if n_links:
            link_targets.append((md, n_links))
        prose_lines = find_prose_mentions(body, args.old, old_path.name)
        if prose_lines:
            prose_targets.append((md, prose_lines))

    rel = lambda p: p.relative_to(root)
    print(f"PLAN: rename {args.type} {args.old} -> {args.new}")
    print(f"  move:   {rel(old_path)}")
    print(f"    ->    {rel(new_path)}")
    print(f"  frontmatter: slug={args.new}, updated={date.today().isoformat()}, aliases += [{args.old}]")
    total_links = sum(n for _, n in link_targets)
    print(f"  link rewrites: {total_links} across {len(link_targets)} file(s)")
    for md, n in link_targets:
        print(f"    {n}x  {rel(md)}")
    if prose_targets:
        print(f"  prose mentions (NOT auto-rewritten — review manually):")
        for md, lines in prose_targets:
            print(f"    {rel(md)}: line(s) {', '.join(map(str, lines))}")

    if args.dry_run:
        print("\nDry run. Omit --dry-run to apply.")
        return

    new_path.write_text(new_fm_text)
    old_path.unlink()
    rewrote = 0
    for md, _ in link_targets:
        body = md.read_text()
        new_body, n = rewrite_links_in(body, args.old, args.new)
        if n:
            md.write_text(new_body)
            rewrote += n
    print(f"\nApplied. Moved file + rewrote {rewrote} link(s) in {len(link_targets)} file(s).")
    if prose_targets:
        print("Prose mentions remain — review manually.")


if __name__ == "__main__":
    main()
