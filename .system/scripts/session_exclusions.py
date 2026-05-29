#!/usr/bin/env python3
"""Shared session exclusion rules for Claude and Codex ingest."""

from __future__ import annotations

import argparse
import fnmatch
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


DEFAULT_RELATIVE_CONFIGS = (
    ".system/config/session-exclusions.json",
    ".system/config/session-exclusions.local.json",
)


class ExclusionConfigError(ValueError):
    pass


@dataclass(frozen=True)
class SessionContext:
    source: str
    session_id: str = ""
    transcript_path: str = ""
    cwd: str = ""
    project_name: str = ""
    git_branch: str = ""
    title: str = ""
    first_user_message: str = ""
    agent_role: str = ""
    agent_path: str = ""
    agent_nickname: str = ""
    thread_source: str = ""


def _load_one(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    try:
        payload = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        raise ExclusionConfigError(f"{path}: invalid JSON: {exc}") from exc
    if not isinstance(payload, dict):
        raise ExclusionConfigError(f"{path}: expected top-level object")
    rules = payload.get("rules", [])
    if not isinstance(rules, list):
        raise ExclusionConfigError(f"{path}: rules must be a list")
    for i, rule in enumerate(rules):
        if not isinstance(rule, dict):
            raise ExclusionConfigError(f"{path}: rules[{i}] must be an object")
        match = rule.get("match", {})
        if match is not None and not isinstance(match, dict):
            raise ExclusionConfigError(f"{path}: rules[{i}].match must be an object")
        for key, value in (match or {}).items():
            values = [value] if isinstance(value, str) else value
            if not isinstance(values, list) or not all(isinstance(item, str) for item in values):
                raise ExclusionConfigError(f"{path}: rules[{i}].match.{key} must be a string or string list")
            if key.endswith("_regexes"):
                for pattern in values:
                    try:
                        re.compile(pattern)
                    except re.error as exc:
                        raise ExclusionConfigError(f"{path}: invalid regex {pattern!r}: {exc}") from exc
    return rules


def load_rules(work_wiki: Path) -> list[dict[str, Any]]:
    rules: list[dict[str, Any]] = []
    for rel in DEFAULT_RELATIVE_CONFIGS:
        rules.extend(_load_one(work_wiki / rel))
    return rules


def _as_list(value: Any) -> list[str]:
    if value is None:
        return []
    if isinstance(value, str):
        return [value]
    if isinstance(value, list) and all(isinstance(item, str) for item in value):
        return value
    raise ExclusionConfigError(f"matcher values must be strings or string lists, got {value!r}")


def _path_has_prefix(path_value: str, prefix: str) -> bool:
    if not path_value:
        return False
    path = Path(path_value).expanduser()
    base = Path(prefix).expanduser()
    try:
        path.resolve(strict=False).relative_to(base.resolve(strict=False))
        return True
    except ValueError:
        return False


def _regex_any(patterns: list[str], text: str) -> bool:
    if not text:
        return False
    for pattern in patterns:
        try:
            if re.search(pattern, text):
                return True
        except re.error as exc:
            raise ExclusionConfigError(f"invalid regex {pattern!r}: {exc}") from exc
    return False


def rule_matches(rule: dict[str, Any], ctx: SessionContext) -> bool:
    if rule.get("enabled", True) is not True:
        return False
    sources = _as_list(rule.get("sources"))
    if sources and ctx.source not in sources:
        return False

    match = rule.get("match") or {}
    if not match:
        return False

    exact_fields = {
        "session_ids": ctx.session_id,
        "repo_names": ctx.project_name,
        "agent_roles": ctx.agent_role,
        "agent_paths": ctx.agent_path,
        "agent_nicknames": ctx.agent_nickname,
        "thread_sources": ctx.thread_source,
    }
    for key, value in exact_fields.items():
        values = _as_list(match.get(key))
        if value and value in values:
            return True

    for prefix in _as_list(match.get("cwd_prefixes")):
        if _path_has_prefix(ctx.cwd, prefix):
            return True

    glob_fields = {
        "cwd_globs": ctx.cwd,
        "git_branch_globs": ctx.git_branch,
        "transcript_path_globs": ctx.transcript_path,
    }
    for key, value in glob_fields.items():
        if value and any(fnmatch.fnmatch(value, pattern) for pattern in _as_list(match.get(key))):
            return True

    regex_fields = {
        "title_regexes": ctx.title,
        "first_user_message_regexes": ctx.first_user_message,
    }
    for key, value in regex_fields.items():
        if _regex_any(_as_list(match.get(key)), value):
            return True

    return False


def excluded_by(rules: list[dict[str, Any]], ctx: SessionContext) -> dict[str, Any] | None:
    for rule in rules:
        if rule_matches(rule, ctx):
            return rule
    return None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--work-wiki", default=str(Path.cwd()))
    parser.add_argument("--source", required=True)
    parser.add_argument("--session-id", default="")
    parser.add_argument("--transcript-path", default="")
    parser.add_argument("--cwd", default="")
    parser.add_argument("--project-name", default="")
    parser.add_argument("--git-branch", default="")
    parser.add_argument("--title", default="")
    parser.add_argument("--first-user-message", default="")
    parser.add_argument("--agent-role", default="")
    parser.add_argument("--agent-path", default="")
    parser.add_argument("--agent-nickname", default="")
    parser.add_argument("--thread-source", default="")
    parser.add_argument("--json", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    ctx = SessionContext(
        source=args.source,
        session_id=args.session_id,
        transcript_path=args.transcript_path,
        cwd=args.cwd,
        project_name=args.project_name,
        git_branch=args.git_branch,
        title=args.title,
        first_user_message=args.first_user_message,
        agent_role=args.agent_role,
        agent_path=args.agent_path,
        agent_nickname=args.agent_nickname,
        thread_source=args.thread_source,
    )
    try:
        match = excluded_by(load_rules(Path(args.work_wiki).expanduser().resolve()), ctx)
    except ExclusionConfigError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    if match:
        if args.json:
            print(json.dumps({"excluded": True, "rule_id": match.get("id", ""), "reason": match.get("reason", "")}))
        return 0
    if args.json:
        print(json.dumps({"excluded": False}))
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
