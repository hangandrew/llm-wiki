#!/usr/bin/env python3
import contextlib
import importlib.util
import io
import json
import sys
import tempfile
import unittest
import urllib.error
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("granola_extract", ROOT / "scripts/granola-extract.py")
granola_extract = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = granola_extract
SPEC.loader.exec_module(granola_extract)


def note(note_id="not_abcdefghijklmn", updated_at="2026-05-14T12:00:00Z", transcript=None, title="Project sync"):
    return {
        "id": note_id,
        "object": "note",
        "title": title,
        "owner": {"name": "Ada", "email": "ada@example.com"},
        "created_at": "2026-05-14T11:00:00Z",
        "updated_at": updated_at,
        "web_url": f"https://notes.granola.ai/d/{note_id}",
        "calendar_event": {"event_title": title},
        "attendees": [{"name": "Ada", "email": "ada@example.com"}],
        "folder_membership": [],
        "summary_text": "Durable thing happened.",
        "summary_markdown": "Durable thing happened.",
        "transcript": transcript if transcript is not None else [{"speaker": {"source": "microphone"}, "text": "We decided X."}],
    }


class FakeClient:
    responses = []
    calls = []

    def __init__(self, api_key, base_url):
        self.api_key = api_key
        self.base_url = base_url

    def get(self, path, params=None):
        self.__class__.calls.append((path, params or {}))
        if not self.__class__.responses:
            raise AssertionError(f"unexpected request: {path} {params}")
        return self.__class__.responses.pop(0)


class GranolaExtractTests(unittest.TestCase):
    def setUp(self):
        self.old_client = granola_extract.Client
        granola_extract.Client = FakeClient
        FakeClient.responses = []
        FakeClient.calls = []

    def tearDown(self):
        granola_extract.Client = self.old_client

    def run_main(self, argv):
        old_argv = sys.argv
        try:
            sys.argv = argv
            stdout = io.StringIO()
            stderr = io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                code = granola_extract.main()
            return code, stdout.getvalue(), stderr.getvalue()
        finally:
            sys.argv = old_argv

    def extract_args(self, root, bundle, state_bundle):
        return [
            "granola-extract.py",
            "--work-wiki",
            str(root),
            "--api-key",
            "key",
            "extract",
            "--updated-after",
            "2026-05-14T00:00:00Z",
            "--run-start",
            "2026-05-14T20:00:00Z",
            "--page-size",
            "30",
            "--bundle",
            str(bundle),
            "--state-bundle",
            str(state_bundle),
        ]

    def test_paginates_with_updated_after_and_fetches_transcript(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            bundle = root / "bundle.jsonl"
            state_bundle = root / "state.jsonl"
            n1 = note("not_aaaaaaaaaaaaaa")
            n2 = note("not_bbbbbbbbbbbbbb")
            FakeClient.responses = [
                (200, {"notes": [{"id": n1["id"], "updated_at": n1["updated_at"]}], "hasMore": True, "cursor": "next"}),
                (200, {"notes": [{"id": n2["id"], "updated_at": n2["updated_at"]}], "hasMore": False, "cursor": None}),
                (200, n1),
                (200, n2),
            ]
            code, stdout, _ = self.run_main(self.extract_args(root, bundle, state_bundle))
            self.assertEqual(code, 0)
            self.assertEqual(json.loads(stdout)["changed"], 2)
            self.assertEqual(FakeClient.calls[0], ("/notes", {"updated_after": "2026-05-14T00:00:00Z", "page_size": 30, "cursor": None}))
            self.assertEqual(FakeClient.calls[1], ("/notes", {"updated_after": "2026-05-14T00:00:00Z", "page_size": 30, "cursor": "next"}))
            self.assertEqual(FakeClient.calls[2][1], {"include": "transcript"})
            self.assertEqual(len(bundle.read_text().splitlines()), 2)

    def test_unchanged_note_hash_is_skipped(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            bundle = root / "bundle.jsonl"
            state_bundle = root / "state.jsonl"
            n = note()
            digest = granola_extract.content_hash(n)
            state_dir = root / ".system/state/granola-notes"
            state_dir.mkdir(parents=True)
            (state_dir / f"{n['id']}.json").write_text(json.dumps({"updated_at": n["updated_at"], "content_hash": digest}))
            FakeClient.responses = [
                (200, {"notes": [{"id": n["id"], "updated_at": n["updated_at"]}], "hasMore": False, "cursor": None}),
                (200, n),
            ]
            code, stdout, _ = self.run_main(self.extract_args(root, bundle, state_bundle))
            self.assertEqual(code, 0)
            self.assertEqual(json.loads(stdout)["unchanged"], 1)
            self.assertEqual(bundle.read_text(), "")
            self.assertEqual(state_bundle.read_text(), "")

    def test_same_updated_at_changed_hash_is_refetched(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            bundle = root / "bundle.jsonl"
            state_bundle = root / "state.jsonl"
            n = note(transcript=[{"speaker": {"source": "microphone"}, "text": "new transcript"}])
            state_dir = root / ".system/state/granola-notes"
            state_dir.mkdir(parents=True)
            (state_dir / f"{n['id']}.json").write_text(json.dumps({"updated_at": n["updated_at"], "content_hash": "old"}))
            FakeClient.responses = [
                (200, {"notes": [{"id": n["id"], "updated_at": n["updated_at"]}], "hasMore": False, "cursor": None}),
                (200, n),
            ]
            code, stdout, _ = self.run_main(self.extract_args(root, bundle, state_bundle))
            self.assertEqual(code, 0)
            self.assertEqual(json.loads(stdout)["changed"], 1)
            self.assertEqual(len(bundle.read_text().splitlines()), 1)

    def test_404_note_is_retry_without_state(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            bundle = root / "bundle.jsonl"
            state_bundle = root / "state.jsonl"
            FakeClient.responses = [
                (200, {"notes": [{"id": "not_aaaaaaaaaaaaaa", "updated_at": "2026-05-14T12:00:00Z"}], "hasMore": False, "cursor": None}),
                (404, None),
            ]
            code, stdout, stderr = self.run_main(self.extract_args(root, bundle, state_bundle))
            self.assertEqual(code, 0)
            self.assertEqual(json.loads(stdout)["retry"], 1)
            self.assertIn("will retry", stderr)
            self.assertEqual(bundle.read_text(), "")
            self.assertEqual(state_bundle.read_text(), "")

    def test_commit_state_persists_only_metadata(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            state_bundle = root / "state.jsonl"
            payload = {
                "id": "not_aaaaaaaaaaaaaa",
                "updated_at": "2026-05-14T12:00:00Z",
                "content_hash": "abc",
                "title": "Project sync",
                "owner": {"email": "ada@example.com"},
                "web_url": "https://notes.granola.ai/d/not_aaaaaaaaaaaaaa",
                "last_processed_at": "2026-05-14T20:00:00Z",
            }
            state_bundle.write_text(json.dumps(payload) + "\n")
            code, stdout, _ = self.run_main([
                "granola-extract.py",
                "--work-wiki",
                str(root),
                "commit-state",
                "--state-bundle",
                str(state_bundle),
            ])
            self.assertEqual(code, 0)
            self.assertEqual(json.loads(stdout)["committed"], 1)
            persisted = json.loads((root / ".system/state/granola-notes/not_aaaaaaaaaaaaaa.json").read_text())
            self.assertNotIn("transcript", persisted)
            self.assertEqual(persisted["content_hash"], "abc")


class FakeHTTPResponse:
    status = 200

    def __init__(self, payload):
        self.payload = payload

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def read(self):
        return json.dumps(self.payload).encode("utf-8")


class GranolaClientTests(unittest.TestCase):
    def test_429_retries_with_backoff(self):
        calls = {"count": 0}
        sleeps = []
        old_urlopen = granola_extract.urllib.request.urlopen

        def fake_urlopen(request, timeout=60):
            calls["count"] += 1
            if calls["count"] == 1:
                raise urllib.error.HTTPError(
                    request.full_url,
                    429,
                    "rate limited",
                    {"Retry-After": "0"},
                    None,
                )
            return FakeHTTPResponse({"notes": [], "hasMore": False, "cursor": None})

        try:
            granola_extract.urllib.request.urlopen = fake_urlopen
            client = granola_extract.Client("key", sleep=lambda seconds: sleeps.append(seconds))
            status, payload = client.get("/notes", {"updated_after": "2026-05-14T00:00:00Z"})
        finally:
            granola_extract.urllib.request.urlopen = old_urlopen

        self.assertEqual(status, 200)
        self.assertEqual(payload["notes"], [])
        self.assertEqual(calls["count"], 2)
        self.assertEqual(sleeps, [1.0])


if __name__ == "__main__":
    unittest.main()
