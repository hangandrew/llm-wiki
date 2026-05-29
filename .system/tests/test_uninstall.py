#!/usr/bin/env python3
import json
import os
import subprocess
import tempfile
import tomllib
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
UNINSTALL = ROOT / "uninstall.sh"


class UninstallTests(unittest.TestCase):
    def test_removes_current_and_legacy_artifacts_under_temp_home(self):
        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            hooks = home / ".claude/hooks"
            hooks.mkdir(parents=True)
            settings = home / ".claude/settings.json"
            claude_md = home / ".claude/CLAUDE.md"
            codex_config = home / ".codex/config.toml"
            launch_agents = home / "Library/LaunchAgents"
            launch_agents.mkdir(parents=True)
            codex_config.parent.mkdir(parents=True)

            (hooks / "wiki-session-end.sh").symlink_to(ROOT / "hooks/wiki-session-end.sh")
            (hooks / "knowledge-session-end.sh").write_text("# legacy\n")
            (hooks / "wiki-updater.sh").write_text("# legacy\n")
            settings.write_text(
                json.dumps(
                    {
                        "env": {
                            "WORK_WIKI_AUTO_PUSH": "1",
                            "WORK_WIKI_SYNTH_PROVIDER": "codex",
                            "WORK_WIKI_SLACK_TOKEN": "xoxp-test",
                            "WORK_TRACKER_DIR": "/tmp/work-tracker",
                            "KEEP_ME": "yes",
                        },
                        "hooks": {
                            "SessionEnd": [
                                {
                                    "hooks": [
                                        {"type": "command", "command": "~/.claude/hooks/wiki-session-end.sh"},
                                        {"type": "command", "command": "~/.claude/hooks/keep-me.sh"},
                                    ]
                                }
                            ]
                        },
                    },
                    indent=2,
                )
            )
            claude_md.write_text(
                "# Global\n\n## Work Wiki <!-- work-wiki -->\n\nRemove me.\n\n## Other\n\nKeep me.\n"
            )
            codex_config.write_text(
                'developer_instructions = "Keep this.\\n\\n## Work Wiki <!-- work-wiki -->\\n\\nRemove me."\n\n[projects."/tmp"]\ntrusted = true\n'
            )
            for name in [
                "com.work-wiki.daily.plist",
                "com.work-wiki.slack-daily.plist",
                "com.work-wiki.granola-daily.plist",
                "com.work-wiki.codex-ingest.plist",
                "com.work-wiki.refactor-weekly.plist",
            ]:
                (launch_agents / name).write_text("<plist/>")

            result = subprocess.run(
                ["bash", str(UNINSTALL), "--yes"],
                cwd=ROOT.parent,
                env={**os.environ, "HOME": str(home)},
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("strip env.WORK_WIKI_* / WORK_TRACKER_* keys", result.stdout)
            self.assertNotIn(",remove", result.stdout)
            self.assertFalse((hooks / "wiki-session-end.sh").exists())
            self.assertFalse((hooks / "knowledge-session-end.sh").exists())
            self.assertFalse((hooks / "wiki-updater.sh").exists())
            for plist in launch_agents.glob("com.work-wiki*.plist"):
                self.fail(f"work-wiki plist was not removed: {plist}")

            updated_settings = json.loads(settings.read_text())
            self.assertEqual(updated_settings["env"], {"KEEP_ME": "yes"})
            remaining_commands = [
                hook["command"]
                for entry in updated_settings["hooks"]["SessionEnd"]
                for hook in entry["hooks"]
            ]
            self.assertEqual(remaining_commands, ["~/.claude/hooks/keep-me.sh"])
            self.assertNotIn("work-wiki", claude_md.read_text())
            self.assertIn("Keep me.", claude_md.read_text())
            parsed_codex = tomllib.loads(codex_config.read_text())
            self.assertEqual(parsed_codex["developer_instructions"], "Keep this.")
            self.assertTrue(parsed_codex["projects"]["/tmp"]["trusted"])


if __name__ == "__main__":
    unittest.main()
