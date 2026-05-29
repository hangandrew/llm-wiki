#!/usr/bin/env python3
"""Pass 1: extract per-transcript metadata into a JSONL index for wiki synthesis.

Reads every `~/.claude/projects/**/*.jsonl` and emits one JSON object per
transcript to `${OUT_FILE}` (default: `${WORK_WIKI}/.system/state/backfill-index.jsonl`).

Triage logic mirrors `wiki-session-end.sh` so passing rows are exactly what
the live hook would have processed.
"""
import json
import os
import re
import sys
import subprocess
from pathlib import Path
from datetime import datetime, timezone

sys.path.insert(0, str(Path(__file__).resolve().parent))
from session_exclusions import ExclusionConfigError, SessionContext, excluded_by, load_rules

TRANSCRIPT_ROOT = Path(os.environ.get("CLAUDE_PROJECTS", os.path.expanduser("~/.claude/projects")))
OUT_FILE = Path(os.environ["OUT_FILE"])
WORK_WIKI = Path(os.environ.get("WORK_WIKI_DIR", OUT_FILE.parents[2])).expanduser().resolve()

LINEAR_RE = re.compile(r"\b[A-Z]{2,}-\d+\b")
SLASH_CMD_RE = re.compile(r"^<command-name>/(exit|clear|logout|compact)")


def parse_ts(s):
    if not s:
        return None
    try:
        s = s.replace("Z", "+00:00").split(".")[0] + ("+00:00" if "+" not in s else "")
        return datetime.fromisoformat(s.replace("+00:00+00:00", "+00:00")).timestamp()
    except Exception:
        try:
            return datetime.fromisoformat(s.rstrip("Z")).replace(tzinfo=timezone.utc).timestamp()
        except Exception:
            return None


def is_real_user(r):
    if r.get("type") != "user":
        return False
    if r.get("isMeta") or r.get("isSidechain"):
        return False
    c = (r.get("message") or {}).get("content")
    if isinstance(c, str):
        if c.startswith("<local-command-stdout>") or c.startswith("<local-command-caveat>"):
            return False
        if SLASH_CMD_RE.match(c):
            return False
    return True


def msg_text(c):
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return " ".join(
            b.get("text", "")
            for b in c
            if isinstance(b, dict) and b.get("type") == "text"
        )
    return ""


def project_name_for(cwd):
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


def extract(path: Path, exclusion_rules):
    records = []
    with path.open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    if not records:
        return None

    entrypoint = next((r.get("entrypoint") for r in records if r.get("entrypoint")), None)

    user_records = [r for r in records if is_real_user(r)]
    asst_count = sum(1 for r in records if r.get("type") == "assistant")

    first_user = user_records[0] if user_records else None
    cwd = first_user.get("cwd") if first_user else None
    git_branch = first_user.get("gitBranch") if first_user else None
    project_name = project_name_for(cwd)

    match = excluded_by(
        exclusion_rules,
        SessionContext(
            source="claude",
            session_id=path.stem,
            transcript_path=str(path),
            cwd=cwd or "",
            project_name=project_name,
            git_branch=git_branch or "",
        ),
    )
    if match:
        return None

    timestamps = [parse_ts(r.get("timestamp")) for r in records]
    timestamps = [t for t in timestamps if t]
    first_ts = min(timestamps) if timestamps else None
    last_ts = max(timestamps) if timestamps else None
    duration = (last_ts - first_ts) if (first_ts and last_ts) else 0

    first_user_msg = ""
    if first_user:
        first_user_msg = msg_text((first_user.get("message") or {}).get("content"))[:500]

    tools = set()
    files = []
    file_seen = set()
    for r in records:
        c = (r.get("message") or {}).get("content")
        if not isinstance(c, list):
            continue
        for b in c:
            if not isinstance(b, dict):
                continue
            if b.get("type") == "tool_use":
                name = b.get("name", "")
                tools.add(name)
                if name in ("Edit", "Write", "Read", "NotebookEdit", "MultiEdit"):
                    inp = b.get("input") or {}
                    fp = inp.get("file_path") or inp.get("notebook_path")
                    if fp and fp not in file_seen:
                        file_seen.add(fp)
                        files.append(fp)

    text_blob = []
    for r in records:
        c = (r.get("message") or {}).get("content")
        if isinstance(c, str):
            text_blob.append(c)
        elif isinstance(c, list):
            for b in c:
                if isinstance(b, dict) and b.get("type") == "text":
                    text_blob.append(b.get("text", ""))
    linear_refs = sorted(set(LINEAR_RE.findall(" ".join(text_blob))))

    user_count = len(user_records)
    passes = (entrypoint != "sdk-cli") and (user_count >= 3) and (duration >= 120)

    return {
        "session_id": path.stem,
        "transcript_path": str(path),
        "cwd": cwd,
        "git_branch": git_branch,
        "entrypoint": entrypoint,
        "first_ts": datetime.fromtimestamp(first_ts, tz=timezone.utc).isoformat().replace("+00:00", "Z") if first_ts else None,
        "last_ts": datetime.fromtimestamp(last_ts, tz=timezone.utc).isoformat().replace("+00:00", "Z") if last_ts else None,
        "duration_sec": int(duration),
        "user_msg_count": user_count,
        "assistant_msg_count": asst_count,
        "first_user_msg": first_user_msg,
        "tools_used": sorted(tools),
        "files_touched": files[:30],
        "linear_refs": linear_refs,
        "passes_triage": passes,
    }


def main():
    paths = sorted(TRANSCRIPT_ROOT.rglob("*.jsonl"))
    print(f"Extracting {len(paths)} transcripts → {OUT_FILE}", file=sys.stderr)
    try:
        exclusion_rules = load_rules(WORK_WIKI)
    except ExclusionConfigError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2
    OUT_FILE.parent.mkdir(parents=True, exist_ok=True)
    written = 0
    with OUT_FILE.open("w") as out:
        for i, p in enumerate(paths, 1):
            try:
                row = extract(p, exclusion_rules)
                if row:
                    out.write(json.dumps(row, default=str) + "\n")
                    written += 1
            except ExclusionConfigError as e:
                print(f"ERROR: {e}", file=sys.stderr)
                return 2
            except Exception as e:
                print(f"  WARN: {p}: {e}", file=sys.stderr)
            if i % 100 == 0:
                print(f"  [{i}/{len(paths)}]", file=sys.stderr)
    print(f"Wrote {written} entries", file=sys.stderr)


if __name__ == "__main__":
    raise SystemExit(main())
