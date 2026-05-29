#!/usr/bin/env python3
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("session_exclusions", ROOT / "scripts/session_exclusions.py")
session_exclusions = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = session_exclusions
SPEC.loader.exec_module(session_exclusions)


class SessionExclusionTests(unittest.TestCase):
    def test_matches_any_configured_matcher(self):
        rule = {
            "enabled": True,
            "sources": ["claude", "codex"],
            "match": {
                "cwd_prefixes": ["/tmp/private"],
                "repo_names": ["secret-repo"],
                "title_regexes": ["(?i)private"],
            },
        }
        ctx = session_exclusions.SessionContext(source="claude", cwd="/tmp/private/project")
        self.assertTrue(session_exclusions.rule_matches(rule, ctx))

    def test_source_scope_blocks_other_sources(self):
        rule = {"enabled": True, "sources": ["codex"], "match": {"repo_names": ["project"]}}
        ctx = session_exclusions.SessionContext(source="claude", project_name="project")
        self.assertFalse(session_exclusions.rule_matches(rule, ctx))

    def test_local_config_extends_committed_config(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            config_dir = root / ".system/config"
            config_dir.mkdir(parents=True)
            (config_dir / "session-exclusions.json").write_text('{"version":1,"rules":[{"id":"a","match":{"repo_names":["a"]}}]}')
            (config_dir / "session-exclusions.local.json").write_text('{"version":1,"rules":[{"id":"b","match":{"repo_names":["b"]}}]}')
            rules = session_exclusions.load_rules(root)
            self.assertEqual([r["id"] for r in rules], ["a", "b"])

    def test_invalid_regex_is_config_error(self):
        rule = {"enabled": True, "match": {"title_regexes": ["["]}}
        ctx = session_exclusions.SessionContext(source="codex", title="private")
        with self.assertRaises(session_exclusions.ExclusionConfigError):
            session_exclusions.rule_matches(rule, ctx)


if __name__ == "__main__":
    unittest.main()
