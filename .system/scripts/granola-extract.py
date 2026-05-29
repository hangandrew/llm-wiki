#!/usr/bin/env python3
"""Fetch changed Granola notes into a temporary process-and-discard bundle."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


API_BASE = "https://public-api.granola.ai/v1"
MAX_RETRIES = 5


class GranolaError(RuntimeError):
    pass


def canonical_json(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def content_hash(note: dict[str, Any]) -> str:
    payload = {
        "id": note.get("id"),
        "title": note.get("title"),
        "owner": note.get("owner"),
        "created_at": note.get("created_at"),
        "updated_at": note.get("updated_at"),
        "web_url": note.get("web_url"),
        "calendar_event": note.get("calendar_event"),
        "attendees": note.get("attendees"),
        "folder_membership": note.get("folder_membership"),
        "summary_text": note.get("summary_text"),
        "summary_markdown": note.get("summary_markdown"),
        "transcript": note.get("transcript"),
    }
    return hashlib.sha256(canonical_json(payload).encode("utf-8")).hexdigest()


def state_payload(note: dict[str, Any], digest: str, processed_at: str) -> dict[str, Any]:
    return {
        "id": note.get("id"),
        "updated_at": note.get("updated_at"),
        "content_hash": digest,
        "title": note.get("title"),
        "owner": note.get("owner"),
        "web_url": note.get("web_url"),
        "last_processed_at": processed_at,
    }


class Client:
    def __init__(self, api_key: str, base_url: str = API_BASE, sleep=time.sleep):
        self.api_key = api_key
        self.base_url = base_url.rstrip("/")
        self.sleep = sleep

    def get(self, path: str, params: dict[str, Any] | None = None) -> tuple[int, Any]:
        url = f"{self.base_url}{path}"
        if params:
            clean = {k: v for k, v in params.items() if v is not None}
            url = f"{url}?{urllib.parse.urlencode(clean)}"
        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Accept": "application/json",
            "User-Agent": "work-wiki-granola-ingest/1",
        }
        request = urllib.request.Request(url, headers=headers)
        delay = 1.0
        for attempt in range(MAX_RETRIES):
            try:
                with urllib.request.urlopen(request, timeout=60) as response:
                    body = response.read().decode("utf-8")
                    return response.status, json.loads(body) if body else None
            except urllib.error.HTTPError as exc:
                if exc.code == 429 and attempt < MAX_RETRIES - 1:
                    retry_after = exc.headers.get("Retry-After")
                    wait = delay
                    if retry_after:
                        try:
                            wait = max(wait, float(retry_after))
                        except ValueError:
                            pass
                    self.sleep(wait)
                    delay = min(delay * 2, 30.0)
                    continue
                if exc.code in (404, 409, 422):
                    return exc.code, None
                try:
                    detail = exc.read().decode("utf-8")[:500]
                except Exception:
                    detail = ""
                raise GranolaError(f"Granola API HTTP {exc.code} for {url}: {detail}") from exc
            except urllib.error.URLError as exc:
                if attempt < MAX_RETRIES - 1:
                    self.sleep(delay)
                    delay = min(delay * 2, 30.0)
                    continue
                raise GranolaError(f"Granola API request failed for {url}: {exc}") from exc
        raise GranolaError(f"Granola API request exhausted retries for {url}")


def read_state(path: Path) -> dict[str, Any] | None:
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return None
    except json.JSONDecodeError:
        return None


def list_notes(client: Client, updated_after: str, page_size: int) -> list[dict[str, Any]]:
    notes: list[dict[str, Any]] = []
    cursor = None
    while True:
        _, page = client.get(
            "/notes",
            {"updated_after": updated_after, "page_size": page_size, "cursor": cursor},
        )
        if not isinstance(page, dict):
            raise GranolaError("Granola list notes returned a non-object response")
        page_notes = page.get("notes")
        if not isinstance(page_notes, list):
            raise GranolaError("Granola list notes response missing notes array")
        notes.extend(n for n in page_notes if isinstance(n, dict))
        cursor = page.get("cursor")
        if not page.get("hasMore") or not cursor:
            break
    return notes


def fetch_note(client: Client, note_id: str) -> tuple[str, dict[str, Any] | None]:
    status, note = client.get(f"/notes/{urllib.parse.quote(note_id)}", {"include": "transcript"})
    if status == 404:
        return "retry", None
    if status in (409, 422):
        return "retry", None
    if not isinstance(note, dict):
        return "retry", None
    return "ok", note


def extract(args: argparse.Namespace) -> int:
    if not args.api_key:
        print("ERROR: WORK_WIKI_GRANOLA_API_KEY is required", file=sys.stderr)
        return 2
    if not args.updated_after:
        print("ERROR: --updated-after is required", file=sys.stderr)
        return 2

    page_size = max(1, min(30, int(args.page_size)))
    work_wiki = Path(args.work_wiki)
    state_dir = work_wiki / ".system/state/granola-notes"
    state_dir.mkdir(parents=True, exist_ok=True)
    bundle_path = Path(args.bundle)
    state_bundle_path = Path(args.state_bundle)
    bundle_path.parent.mkdir(parents=True, exist_ok=True)
    state_bundle_path.parent.mkdir(parents=True, exist_ok=True)

    client = Client(args.api_key, args.base_url)
    listed = list_notes(client, args.updated_after, page_size)
    seen: set[str] = set()
    stats = {"listed": len(listed), "changed": 0, "unchanged": 0, "retry": 0}

    with bundle_path.open("w", encoding="utf-8") as bundle, state_bundle_path.open("w", encoding="utf-8") as state_bundle:
        for listed_note in listed:
            note_id = listed_note.get("id")
            if not isinstance(note_id, str) or note_id in seen:
                continue
            seen.add(note_id)
            current_state = read_state(state_dir / f"{note_id}.json")
            status, note = fetch_note(client, note_id)
            if status != "ok" or note is None:
                stats["retry"] += 1
                print(f"WARN: note {note_id} was listed but not fetchable; will retry next run", file=sys.stderr)
                continue
            digest = content_hash(note)
            if (
                current_state
                and current_state.get("updated_at") == note.get("updated_at")
                and current_state.get("content_hash") == digest
            ):
                stats["unchanged"] += 1
                continue
            stats["changed"] += 1
            bundle.write(canonical_json({"source": "granola", "note": note}) + "\n")
            state_bundle.write(canonical_json(state_payload(note, digest, args.run_start)) + "\n")

    print(canonical_json(stats))
    return 0


def commit_state(args: argparse.Namespace) -> int:
    state_dir = Path(args.work_wiki) / ".system/state/granola-notes"
    state_dir.mkdir(parents=True, exist_ok=True)
    count = 0
    with Path(args.state_bundle).open(encoding="utf-8") as f:
        for line in f:
            if not line.strip():
                continue
            payload = json.loads(line)
            note_id = payload.get("id")
            if not isinstance(note_id, str):
                continue
            tmp = state_dir / f"{note_id}.json.tmp"
            final = state_dir / f"{note_id}.json"
            tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            tmp.replace(final)
            count += 1
    print(canonical_json({"committed": count}))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--work-wiki", default=os.environ.get("WORK_WIKI_DIR", str(Path.home() / "work-wiki")))
    parser.add_argument("--api-key", default=os.environ.get("WORK_WIKI_GRANOLA_API_KEY", ""))
    parser.add_argument("--base-url", default=os.environ.get("WORK_WIKI_GRANOLA_BASE_URL", API_BASE))
    sub = parser.add_subparsers(dest="command")

    extract_parser = sub.add_parser("extract")
    extract_parser.add_argument("--updated-after", required=True)
    extract_parser.add_argument("--run-start", required=True)
    extract_parser.add_argument("--page-size", default=os.environ.get("WORK_WIKI_GRANOLA_PAGE_SIZE", "30"))
    extract_parser.add_argument("--bundle", required=True)
    extract_parser.add_argument("--state-bundle", required=True)

    commit_parser = sub.add_parser("commit-state")
    commit_parser.add_argument("--state-bundle", required=True)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        if args.command == "extract":
            return extract(args)
        if args.command == "commit-state":
            return commit_state(args)
        parser.print_help(sys.stderr)
        return 2
    except GranolaError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
