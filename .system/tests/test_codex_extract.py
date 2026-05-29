#!/usr/bin/env python3
import importlib.util
import contextlib
import io
import json
import sqlite3
import sys
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("codex_extract", ROOT / "scripts/codex-extract.py")
codex_extract = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = codex_extract
SPEC.loader.exec_module(codex_extract)


def write_rollout(path: Path, user_messages: int = 3) -> None:
    rows = [
        {"type": "session_meta", "payload": {"cwd": "/tmp/project", "id": "thread-1"}},
        {
            "type": "response_item",
            "payload": {"type": "message", "role": "developer", "content": [{"type": "input_text", "text": "ignore"}]},
        },
    ]
    for i in range(user_messages):
        rows.append(
            {
                "type": "response_item",
                "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": f"user {i}"}]},
            }
        )
        rows.append(
            {
                "type": "response_item",
                "payload": {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": f"assistant {i}"}]},
            }
        )
    path.write_text("".join(json.dumps(r) + "\n" for r in rows))


def create_db(
    path: Path,
    rollout: Path,
    updated_at: int | None = None,
    cwd: str = "/tmp/project",
    title: str = "Test title",
    git_branch: str = "main",
    first_user_message: str = "First user",
) -> None:
    now = int(time.time())
    updated = updated_at if updated_at is not None else now - 3600
    conn = sqlite3.connect(path)
    conn.execute(
        """
        create table threads (
          id text primary key,
          rollout_path text not null,
          created_at integer not null,
          updated_at integer not null,
          source text not null,
          model_provider text not null,
          cwd text not null,
          title text not null,
          sandbox_policy text not null,
          approval_mode text not null,
          archived integer not null default 0,
          git_branch text,
          first_user_message text not null default '',
          agent_nickname text,
          agent_role text,
          agent_path text,
          thread_source text,
          created_at_ms integer,
          updated_at_ms integer
        )
        """
    )
    conn.execute(
        """
        insert into threads (
          id, rollout_path, created_at, updated_at, source, model_provider, cwd, title,
          sandbox_policy, approval_mode, archived, git_branch, first_user_message,
          created_at_ms, updated_at_ms
        ) values (?, ?, ?, ?, 'vscode', 'openai', ?, ?, '{}', 'on-request', 0, ?, ?, ?, ?)
        """,
        (
            "thread-1",
            str(rollout),
            updated - 300,
            updated,
            cwd,
            title,
            git_branch,
            first_user_message,
            (updated - 300) * 1000,
            updated * 1000,
        ),
    )
    conn.commit()
    conn.close()


class CodexExtractTests(unittest.TestCase):
    def run_main(self, argv):
        old_argv = sys.argv
        try:
            sys.argv = argv
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                return codex_extract.main()
        finally:
            sys.argv = old_argv

    def test_rollout_stats_counts_real_user_messages(self):
        with tempfile.TemporaryDirectory() as td:
            rollout = Path(td) / "rollout.jsonl"
            write_rollout(rollout, user_messages=4)
            line_count, user_count, first_user = codex_extract.rollout_stats(rollout)
            self.assertEqual(line_count, 10)
            self.assertEqual(user_count, 4)
            self.assertEqual(first_user, "user 0")

    def test_inactive_changed_thread_enqueues_pending(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            rollout = root / "rollout.jsonl"
            db = root / "state.sqlite"
            work_wiki = root / "wiki"
            write_rollout(rollout, user_messages=3)
            create_db(db, rollout)
            self.assertEqual(
                self.run_main([
                    "codex-extract.py",
                    "--work-wiki",
                    str(work_wiki),
                    "--state-db",
                    str(db),
                    "--enqueue",
                    "--json",
                ]),
                0,
            )
            pending = list((work_wiki / ".system/state/pending").glob("*.json"))
            self.assertEqual(len(pending), 1)
            payload = json.loads(pending[0].read_text())
            self.assertEqual(payload["source"], "codex")
            self.assertEqual(payload["cursor_type"], "line")
            self.assertEqual(payload["session_cwd"], "/tmp/project")
            self.assertEqual(payload["git_branch"], "main")
            self.assertEqual(payload["title"], "Test title")

    def test_exclusion_config_skips_matching_thread(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            rollout = root / "rollout.jsonl"
            db = root / "state.sqlite"
            work_wiki = root / "wiki"
            config_dir = work_wiki / ".system/config"
            config_dir.mkdir(parents=True)
            (config_dir / "session-exclusions.json").write_text(json.dumps({
                "version": 1,
                "rules": [
                    {
                        "id": "skip-private",
                        "sources": ["codex"],
                        "match": {"cwd_prefixes": [str(root / "private")]},
                    }
                ],
            }))
            write_rollout(rollout, user_messages=3)
            create_db(db, rollout, cwd=str(root / "private/project"))

            self.assertEqual(
                self.run_main([
                    "codex-extract.py",
                    "--work-wiki",
                    str(work_wiki),
                    "--state-db",
                    str(db),
                    "--enqueue",
                    "--json",
                ]),
                0,
            )
            self.assertFalse((work_wiki / ".system/state/pending").exists())

    def test_active_thread_is_skipped(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            rollout = root / "rollout.jsonl"
            db = root / "state.sqlite"
            work_wiki = root / "wiki"
            write_rollout(rollout, user_messages=3)
            create_db(db, rollout, updated_at=int(time.time()))
            self.assertEqual(
                self.run_main(["codex-extract.py", "--work-wiki", str(work_wiki), "--state-db", str(db), "--enqueue"]),
                0,
            )
            self.assertFalse((work_wiki / ".system/state/pending").exists())

    def test_cursor_current_emits_no_pending_until_new_lines_append(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            rollout = root / "rollout.jsonl"
            db = root / "state.sqlite"
            work_wiki = root / "wiki"
            write_rollout(rollout, user_messages=3)
            create_db(db, rollout)
            with rollout.open() as f:
                line_count = sum(1 for _ in f)
            cursor_dir = work_wiki / ".system/state/codex-sessions"
            cursor_dir.mkdir(parents=True)
            (cursor_dir / "thread-1.line").write_text(str(line_count))

            self.assertEqual(
                self.run_main(["codex-extract.py", "--work-wiki", str(work_wiki), "--state-db", str(db), "--enqueue"]),
                0,
            )
            self.assertFalse((work_wiki / ".system/state/pending").exists())
            with rollout.open("a") as f:
                f.write(json.dumps({"type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "new"}]}}) + "\n")
            self.assertEqual(
                self.run_main(["codex-extract.py", "--work-wiki", str(work_wiki), "--state-db", str(db), "--enqueue"]),
                0,
            )
            pending = list((work_wiki / ".system/state/pending").glob("*.json"))
            self.assertEqual(len(pending), 1)


if __name__ == "__main__":
    unittest.main()
