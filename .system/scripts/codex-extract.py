#!/usr/bin/env python3
"""Extract Codex thread metadata and enqueue changed rollout files.

Codex stores thread metadata in `~/.codex/state_5.sqlite` and raw rollouts as
JSONL files. This script keeps the shell integration small: it reads the SQLite
index, applies the same substantive-session gates as the Claude hook, compares
each rollout line count to `.system/state/codex-sessions/<thread_id>.line`, and
writes source-aware pending entries for changed, idle sessions.
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from session_exclusions import ExclusionConfigError, SessionContext, excluded_by, load_rules


MIN_USER_MESSAGES = 3
MIN_DURATION_SECONDS = 120


@dataclass
class Thread:
    id: str
    rollout_path: str
    cwd: str
    git_branch: str
    title: str
    first_user_message: str
    archived: int
    created_at: int
    updated_at: int
    created_at_ms: int | None
    updated_at_ms: int | None
    agent_nickname: str
    agent_role: str
    agent_path: str
    thread_source: str


def iso_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def compact_ts() -> str:
    return datetime.now().strftime("%Y%m%dT%H%M%S")


def text_from_content(content: Any) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for item in content:
            if isinstance(item, dict):
                parts.append(str(item.get("text") or item.get("input_text") or item.get("output_text") or ""))
        return " ".join(p for p in parts if p)
    return ""


def is_real_codex_user_message(record: dict[str, Any]) -> bool:
    if record.get("type") != "response_item":
        return False
    payload = record.get("payload") or {}
    if payload.get("type") != "message" or payload.get("role") != "user":
        return False
    text = text_from_content(payload.get("content")).strip()
    if not text:
        return False
    if text.startswith("<environment_context>") and "</environment_context>" in text and text.endswith("</environment_context>"):
        return False
    return True


def rollout_stats(path: Path) -> tuple[int, int, str]:
    line_count = 0
    user_count = 0
    first_user = ""
    with path.open() as f:
        for line in f:
            if not line.strip():
                continue
            line_count += 1
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            if is_real_codex_user_message(record):
                user_count += 1
                if not first_user:
                    first_user = text_from_content((record.get("payload") or {}).get("content"))[:500]
    return line_count, user_count, first_user


def epoch_seconds(value: int | None, fallback: int = 0) -> float:
    if value is None:
        return float(fallback or 0)
    if value > 10_000_000_000:
        return value / 1000.0
    return float(value)


def project_name_for(cwd: str) -> str:
    if not cwd:
        return "unknown"
    home = str(Path.home())
    try:
        repo = subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--show-toplevel"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        ).stdout.strip()
    except OSError:
        repo = ""
    if repo:
        return Path(repo).name
    if cwd in (home, home + os.sep):
        return "home"
    return Path(cwd).name or "unknown"


def read_cursor(path: Path) -> int:
    try:
        return int(path.read_text().strip())
    except (OSError, ValueError):
        return 0


def is_subagent_or_background(row: Thread) -> bool:
    for value in (row.agent_role, row.agent_path, row.agent_nickname):
        if value:
            return True
    return (row.thread_source or "").lower() in {"subagent", "background"}


def load_threads(db_path: Path) -> list[Thread]:
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    try:
        columns = {r["name"] for r in conn.execute("pragma table_info(threads)")}
        optional = {
            "git_branch": "",
            "title": "",
            "first_user_message": "",
            "created_at_ms": None,
            "updated_at_ms": None,
            "agent_nickname": "",
            "agent_role": "",
            "agent_path": "",
            "thread_source": "",
        }
        select_cols = ["id", "rollout_path", "cwd", "archived", "created_at", "updated_at"]
        select_cols.extend(c for c in optional if c in columns)
        rows = conn.execute(
            f"select {', '.join(select_cols)} from threads order by updated_at desc, id desc"
        ).fetchall()
    finally:
        conn.close()

    threads: list[Thread] = []
    for row in rows:
        data = dict(row)
        for key, default in optional.items():
            data.setdefault(key, default)
        threads.append(Thread(**data))
    return threads


def pending_payload(row: Thread, line_count: int, cursor: int, first_user: str) -> dict[str, Any]:
    return {
        "source": "codex",
        "session_id": row.id,
        "transcript_path": row.rollout_path,
        "session_cwd": row.cwd,
        "project_name": project_name_for(row.cwd),
        "git_branch": row.git_branch or "",
        "cursor_type": "line",
        "last_cursor": str(cursor),
        "enqueued_at": iso_now(),
        "title": row.title or first_user[:120],
        "first_user_message": row.first_user_message or first_user,
        "line_count": line_count,
    }


def exclusion_context(row: Thread) -> SessionContext:
    return SessionContext(
        source="codex",
        session_id=row.id,
        transcript_path=row.rollout_path,
        cwd=row.cwd,
        project_name=project_name_for(row.cwd),
        git_branch=row.git_branch or "",
        title=row.title or "",
        first_user_message=row.first_user_message or "",
        agent_role=row.agent_role or "",
        agent_path=row.agent_path or "",
        agent_nickname=row.agent_nickname or "",
        thread_source=row.thread_source or "",
    )


def enqueue(work_wiki: Path, payload: dict[str, Any]) -> Path:
    pending_dir = work_wiki / ".system/state/pending"
    pending_dir.mkdir(parents=True, exist_ok=True)
    sid = payload["session_id"]
    path = pending_dir / f"{sid}-{compact_ts()}.json"
    tmp = pending_dir / f".{path.name}.tmp"
    tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    tmp.replace(path)
    return path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--work-wiki", default=os.environ.get("WORK_WIKI_DIR", os.getcwd()))
    parser.add_argument("--state-db", default=os.environ.get("WORK_WIKI_CODEX_STATE_DB", "~/.codex/state_5.sqlite"))
    parser.add_argument("--idle-minutes", type=int, default=int(os.environ.get("WORK_WIKI_CODEX_IDLE_MINUTES", "10")))
    parser.add_argument("--enqueue", action="store_true")
    parser.add_argument("--include-active", action="store_true", help="Ignore idle delay; useful for backfill/tests.")
    parser.add_argument("--all", action="store_true", help="Do not skip rows already covered by the line cursor.")
    parser.add_argument("--index", help="Write metadata JSONL instead of, or in addition to, enqueueing.")
    parser.add_argument("--json", action="store_true", help="Print summary JSON to stdout.")
    args = parser.parse_args()

    work_wiki = Path(args.work_wiki).expanduser().resolve()
    db_path = Path(args.state_db).expanduser()
    if not db_path.exists():
        print(f"ERROR: Codex state DB not found: {db_path}", file=sys.stderr)
        return 1

    cursor_dir = work_wiki / ".system/state/codex-sessions"
    cursor_dir.mkdir(parents=True, exist_ok=True)
    try:
        exclusion_rules = load_rules(work_wiki)
    except ExclusionConfigError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    now = time.time()
    rows_out = []
    summary = {"seen": 0, "eligible": 0, "enqueued": 0, "skipped": {}}

    for row in load_threads(db_path):
        summary["seen"] += 1
        skip_reason = ""
        rollout = Path(row.rollout_path).expanduser()
        if row.archived:
            skip_reason = "archived"
        elif is_subagent_or_background(row):
            skip_reason = "subagent"
        elif not rollout.exists():
            skip_reason = "missing-rollout"
        elif not args.include_active and (now - epoch_seconds(row.updated_at_ms, row.updated_at)) < args.idle_minutes * 60:
            skip_reason = "active"
        else:
            try:
                exclusion_rule = excluded_by(exclusion_rules, exclusion_context(row))
            except ExclusionConfigError as exc:
                print(f"ERROR: {exc}", file=sys.stderr)
                return 2
            if exclusion_rule:
                skip_reason = "excluded"

        if skip_reason:
            summary["skipped"][skip_reason] = summary["skipped"].get(skip_reason, 0) + 1
            continue

        line_count, user_count, first_user = rollout_stats(rollout)
        duration = int(epoch_seconds(row.updated_at_ms, row.updated_at) - epoch_seconds(row.created_at_ms, row.created_at))
        cursor_file = cursor_dir / f"{row.id}.line"
        cursor = read_cursor(cursor_file)
        passes = user_count >= MIN_USER_MESSAGES and duration >= MIN_DURATION_SECONDS
        metadata = pending_payload(row, line_count, cursor, first_user)
        metadata.update(
            {
                "id": row.id,
                "source": "codex",
                "cwd": row.cwd,
                "duration_sec": duration,
                "user_msg_count": user_count,
                "passes_triage": passes,
                "first_ts": datetime.fromtimestamp(epoch_seconds(row.created_at_ms, row.created_at), tz=timezone.utc).isoformat().replace("+00:00", "Z"),
                "last_ts": datetime.fromtimestamp(epoch_seconds(row.updated_at_ms, row.updated_at), tz=timezone.utc).isoformat().replace("+00:00", "Z"),
            }
        )
        rows_out.append(metadata)

        if not passes:
            summary["skipped"]["triage"] = summary["skipped"].get("triage", 0) + 1
            continue
        if line_count <= cursor and not args.all:
            summary["skipped"]["cursor-current"] = summary["skipped"].get("cursor-current", 0) + 1
            continue

        summary["eligible"] += 1
        if args.enqueue:
            enqueue(work_wiki, pending_payload(row, line_count, cursor, first_user))
            summary["enqueued"] += 1

    if args.index:
        out = Path(args.index).expanduser()
        out.parent.mkdir(parents=True, exist_ok=True)
        with out.open("w") as f:
            for row in rows_out:
                f.write(json.dumps(row, sort_keys=True) + "\n")

    if args.json:
        print(json.dumps(summary, sort_keys=True))
    else:
        print(
            f"Codex extract: seen={summary['seen']} eligible={summary['eligible']} enqueued={summary['enqueued']} skipped={summary['skipped']}",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
