#!/usr/bin/env python3
"""Detect synthesis pages that are stale relative to the entity pages they link to.

A synthesis page (decisions log, open questions, recurring bugs) summarizes state
across the wiki. When entity pages it references have been updated more recently,
the synthesis may be out of date — questions resolved, decisions revised, bugs
fixed. This script surfaces those cases via frontmatter date math.

No LLM call. Pure detection. The user (or a downstream agent) decides what to update.

Usage:
  detect-synthesis-rot.py [--threshold-days N] [--json]

Default threshold: 7 days. A synthesis is "rotting" when at least one linked
entity has `updated:` newer by >= threshold days.

What it does NOT do:
  - Read content. The signal is dates, not semantics. Whether a referenced
    question was actually resolved by a later session is a human/LLM call.
  - Auto-update anything. Detection only.
  - Scan lint-*.md reports. Those are frozen snapshots, not maintained pages.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import date
from pathlib import Path

UPDATED_RE = re.compile(r"^updated:\s*(\d{4}-\d{2}-\d{2})", re.M)
MD_LINK_RE = re.compile(r"\]\(([^)]+)\)")


def wiki_root() -> Path:
    return Path(__file__).resolve().parents[2]


def frontmatter_date(path: Path) -> date | None:
    try:
        text = path.read_text()
    except OSError:
        return None
    if not text.startswith("---\n"):
        return None
    end = text.find("\n---\n", 4)
    if end == -1:
        return None
    m = UPDATED_RE.search(text[4:end])
    if not m:
        return None
    try:
        return date.fromisoformat(m.group(1))
    except ValueError:
        return None


def extract_md_link_targets(text: str) -> list[str]:
    targets: list[str] = []
    for m in MD_LINK_RE.finditer(text):
        target = m.group(1)
        if "://" in target:
            continue
        target = target.split("#", 1)[0].strip()
        if target.endswith(".md"):
            targets.append(target)
    return targets


def scan_synthesis(synth_path: Path) -> dict:
    synth_date = frontmatter_date(synth_path)
    if synth_date is None:
        return {"path": str(synth_path), "error": "no updated frontmatter"}

    text = synth_path.read_text()
    targets = extract_md_link_targets(text)

    linked: dict[Path, date] = {}
    for link in targets:
        resolved = (synth_path.parent / link).resolve()
        if resolved == synth_path or not resolved.exists():
            continue
        if resolved in linked:
            continue
        d = frontmatter_date(resolved)
        if d is not None:
            linked[resolved] = d

    newer = sorted(
        (
            (p, d, (d - synth_date).days)
            for p, d in linked.items()
            if d > synth_date
        ),
        key=lambda t: t[2],
        reverse=True,
    )

    return {
        "path": str(synth_path),
        "updated": synth_date.isoformat(),
        "linked": len(linked),
        "newer_count": len(newer),
        "max_delta_days": newer[0][2] if newer else 0,
        "newer_pages": [
            {"path": str(p), "updated": d.isoformat(), "delta_days": delta}
            for p, d, delta in newer
        ],
    }


def main() -> None:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument(
        "--threshold-days",
        type=int,
        default=7,
        help="flag syntheses where the newest linked entity is >= N days newer (default 7)",
    )
    ap.add_argument("--json", action="store_true", help="emit JSON instead of text")
    args = ap.parse_args()

    root = wiki_root()
    synths_dir = root / "wiki" / "syntheses"
    if not synths_dir.is_dir():
        sys.exit(f"ERROR: {synths_dir} does not exist")

    # Skip operational artifacts that are regenerated/appended, not maintained:
    #   lint-*.md             — frozen snapshots from .system/scripts/lint.sh
    #   refactor-proposals.md — legacy; predecessor of refactor-intents.md
    #   refactor-intents.md   — append-only intent queue consumed by refactor-review
    SKIP_NAMES = {"refactor-proposals.md", "refactor-intents.md"}
    synths = [
        p
        for p in sorted(synths_dir.glob("*.md"))
        if not p.name.startswith("lint-") and p.name not in SKIP_NAMES
    ]

    reports = [scan_synthesis(p) for p in synths]
    rot = [
        r
        for r in reports
        if r.get("newer_count", 0) >= 1
        and r.get("max_delta_days", 0) >= args.threshold_days
    ]
    rot.sort(key=lambda r: r["max_delta_days"], reverse=True)

    if args.json:
        print(json.dumps(rot, indent=2))
        return

    rel = lambda p: Path(p).relative_to(root)
    if not rot:
        print(f"No synthesis pages rotting (threshold: {args.threshold_days} days).")
        print(f"Scanned {len(reports)} synthesis page(s).")
        return

    for r in rot:
        print(
            f"{rel(r['path'])}  updated {r['updated']}  "
            f"rot={r['max_delta_days']}d  "
            f"newer_links={r['newer_count']}/{r['linked']}"
        )
        for n in r["newer_pages"][:5]:
            print(f"  +{n['delta_days']}d  {n['updated']}  {rel(n['path'])}")
        if len(r["newer_pages"]) > 5:
            print(f"  ... and {len(r['newer_pages']) - 5} more")
        print()
    print(f"Total rotting syntheses: {len(rot)} (threshold: {args.threshold_days} days)")


if __name__ == "__main__":
    main()
