#!/usr/bin/env python3
import contextlib
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("slack_prefetch", ROOT / "scripts/slack-prefetch.py")
slack_prefetch = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = slack_prefetch
SPEC.loader.exec_module(slack_prefetch)


class FakeClient:
    calls = []

    def __init__(self, token, base_url):
        self.token = token
        self.base_url = base_url

    def api(self, method, params=None):
        self.__class__.calls.append((method, params or {}))
        if method == "auth.test":
            return {"ok": True, "user_id": "U123"}
        if method == "search.messages":
            return {
                "ok": True,
                "messages": {
                    "matches": [
                        {
                            "ts": "1770000000.000100",
                            "thread_ts": "1770000000.000000",
                            "channel": {"id": "C123"},
                            "text": "Durable project decision",
                        },
                        {
                            "ts": "1770000001.000100",
                            "thread_ts": "1770000000.000000",
                            "channel": {"id": "C123"},
                            "text": "Same thread reply",
                        },
                    ],
                    "paging": {"page": 1, "pages": 1},
                },
            }
        if method == "conversations.replies":
            return {
                "ok": True,
                "messages": [
                    {"ts": "1770000000.000000", "text": "Parent"},
                    {"ts": "1770000000.000100", "text": "Reply"},
                ],
            }
        raise AssertionError(f"unexpected method {method}")


class SlackPrefetchTests(unittest.TestCase):
    def setUp(self):
        self.old_client = slack_prefetch.Client
        slack_prefetch.Client = FakeClient
        FakeClient.calls = []

    def tearDown(self):
        slack_prefetch.Client = self.old_client

    def run_main(self, argv):
        old_argv = sys.argv
        try:
            sys.argv = argv
            stdout = io.StringIO()
            stderr = io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                code = slack_prefetch.main()
            return code, stdout.getvalue(), stderr.getvalue()
        finally:
            sys.argv = old_argv

    def test_writes_bundle_and_dedupes_thread_reads(self):
        with tempfile.TemporaryDirectory() as td:
            bundle = Path(td) / "slack.jsonl"
            code, stdout, stderr = self.run_main(
                [
                    "slack-prefetch.py",
                    "--token",
                    "xoxp-test",
                    "extract",
                    "--since",
                    "2026-05-14T00:00:00Z",
                    "--run-start",
                    "2026-05-15T00:00:00Z",
                    "--bundle",
                    str(bundle),
                    "--limit",
                    "100",
                ]
            )
            self.assertEqual(code, 0, stderr)
            self.assertEqual(json.loads(stdout), {"messages": 2, "threads": 1, "user_id": "U123"})
            payload = json.loads(bundle.read_text().strip())
            self.assertEqual(payload["source"], "slack")
            self.assertEqual(len(payload["messages"]), 2)
            self.assertEqual(len(payload["threads"]), 1)
            self.assertEqual(
                [call[0] for call in FakeClient.calls],
                ["auth.test", "search.messages", "conversations.replies"],
            )
            self.assertEqual(FakeClient.calls[1][1]["query"], "from:<@U123> after:2026-05-14")


if __name__ == "__main__":
    unittest.main()
