#!/usr/bin/env python3
"""Fetch recent Slack messages into a temporary process-and-discard bundle."""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any


API_BASE = "https://slack.com/api"
MAX_RETRIES = 5


class SlackError(RuntimeError):
    pass


def canonical_json(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def iso_to_slack_after(value: str) -> str:
    # Slack search accepts YYYY-MM-DD in after:, while conversations.replies
    # expects a Unix timestamp string. Search is coarse; cursor advancement is
    # still guarded by run-start and failed runs keep the old cursor.
    return value[:10]


class Client:
    def __init__(self, token: str, base_url: str = API_BASE, sleep=time.sleep):
        self.token = token
        self.base_url = base_url.rstrip("/")
        self.sleep = sleep

    def api(self, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        url = f"{self.base_url}/{method}"
        body = urllib.parse.urlencode({k: v for k, v in (params or {}).items() if v is not None}).encode()
        headers = {
            "Authorization": f"Bearer {self.token}",
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json",
            "User-Agent": "work-wiki-slack-ingest/1",
        }
        request = urllib.request.Request(url, data=body, headers=headers, method="POST")
        delay = 1.0
        for attempt in range(MAX_RETRIES):
            try:
                with urllib.request.urlopen(request, timeout=60) as response:
                    payload = json.loads(response.read().decode("utf-8") or "{}")
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
                detail = exc.read().decode("utf-8", errors="replace")[:500]
                raise SlackError(f"Slack API HTTP {exc.code} for {method}: {detail}") from exc
            except urllib.error.URLError as exc:
                if attempt < MAX_RETRIES - 1:
                    self.sleep(delay)
                    delay = min(delay * 2, 30.0)
                    continue
                raise SlackError(f"Slack API request failed for {method}: {exc}") from exc

            if payload.get("ok"):
                return payload
            error = payload.get("error", "unknown_error")
            if error == "ratelimited" and attempt < MAX_RETRIES - 1:
                self.sleep(delay)
                delay = min(delay * 2, 30.0)
                continue
            raise SlackError(f"Slack API {method} failed: {error}")
        raise SlackError(f"Slack API request exhausted retries for {method}")


def get_user_id(client: Client) -> str:
    payload = client.api("auth.test")
    user_id = payload.get("user_id") or payload.get("bot_id")
    if not isinstance(user_id, str) or not user_id:
        raise SlackError("auth.test response did not include user_id")
    return user_id


def search_messages(client: Client, user_id: str, since: str, limit: int) -> list[dict[str, Any]]:
    query = f"from:<@{user_id}> after:{iso_to_slack_after(since)}"
    matches: list[dict[str, Any]] = []
    page = 1
    while len(matches) < limit:
        payload = client.api(
            "search.messages",
            {
                "query": query,
                "count": min(100, limit - len(matches)),
                "page": page,
                "sort": "timestamp",
                "sort_dir": "asc",
            },
        )
        messages = payload.get("messages", {})
        page_matches = messages.get("matches", []) if isinstance(messages, dict) else []
        matches.extend(m for m in page_matches if isinstance(m, dict))
        paging = messages.get("paging", {}) if isinstance(messages, dict) else {}
        pages = int(paging.get("pages") or page)
        if page >= pages or not page_matches:
            break
        page += 1
    return matches


def channel_id_for(match: dict[str, Any]) -> str | None:
    channel = match.get("channel")
    if isinstance(channel, dict) and isinstance(channel.get("id"), str):
        return channel["id"]
    if isinstance(match.get("channel_id"), str):
        return match["channel_id"]
    return None


def thread_ts_for(match: dict[str, Any]) -> str | None:
    ts = match.get("ts")
    thread_ts = match.get("thread_ts")
    if isinstance(thread_ts, str) and thread_ts and thread_ts != ts:
        return thread_ts
    if isinstance(match.get("iid"), str) and "-" in match["iid"]:
        return match["iid"].rsplit("-", 1)[-1]
    return None


def fetch_threads(client: Client, matches: list[dict[str, Any]]) -> list[dict[str, Any]]:
    threads: list[dict[str, Any]] = []
    seen: set[tuple[str, str]] = set()
    for match in matches:
        channel = channel_id_for(match)
        thread_ts = thread_ts_for(match)
        if not channel or not thread_ts:
            continue
        key = (channel, thread_ts)
        if key in seen:
            continue
        seen.add(key)
        payload = client.api("conversations.replies", {"channel": channel, "ts": thread_ts, "limit": 200})
        replies = payload.get("messages", [])
        threads.append(
            {
                "channel": channel,
                "thread_ts": thread_ts,
                "messages": replies if isinstance(replies, list) else [],
            }
        )
    return threads


def extract(args: argparse.Namespace) -> int:
    token = args.token or os.environ.get("WORK_WIKI_SLACK_TOKEN") or os.environ.get("SLACK_USER_TOKEN") or os.environ.get("SLACK_BOT_TOKEN")
    if not token:
        print("ERROR: WORK_WIKI_SLACK_TOKEN is required", file=sys.stderr)
        return 2
    client = Client(token, args.base_url)
    user_id = get_user_id(client)
    matches = search_messages(client, user_id, args.since, int(args.limit))
    threads = fetch_threads(client, matches)
    bundle = {
        "source": "slack",
        "run_start": args.run_start,
        "since": args.since,
        "user_id": user_id,
        "messages": matches,
        "threads": threads,
    }
    with open(args.bundle, "w", encoding="utf-8") as f:
        f.write(canonical_json(bundle) + "\n")
    print(canonical_json({"messages": len(matches), "threads": len(threads), "user_id": user_id}))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--token", default="")
    parser.add_argument("--base-url", default=os.environ.get("WORK_WIKI_SLACK_BASE_URL", API_BASE))
    parser.add_argument("extract")
    parser.add_argument("--since", required=True)
    parser.add_argument("--run-start", required=True)
    parser.add_argument("--bundle", required=True)
    parser.add_argument("--limit", default=os.environ.get("WORK_WIKI_SLACK_LIMIT", "100"))
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    if args.extract != "extract":
        parser.print_help(sys.stderr)
        return 2
    try:
        return extract(args)
    except SlackError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
