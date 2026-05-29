#!/usr/bin/env python3
import os
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / "scripts/headless-agent-run.sh"


class HeadlessAgentRunTests(unittest.TestCase):
    def run_provider(self, env=None):
        merged = os.environ.copy()
        for key in list(merged):
            if key.startswith("WORK_WIKI_") and key.endswith("_SYNTH_PROVIDER"):
                merged.pop(key)
        merged.pop("WORK_WIKI_SYNTH_PROVIDER", None)
        merged.update(env or {})
        result = subprocess.run(
            [str(RUNNER), "--job", "slack", "--print-provider"],
            text=True,
            capture_output=True,
            env=merged,
            check=False,
        )
        return result

    def test_default_resolves_to_claude(self):
        result = self.run_provider()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "claude")

    def test_global_env_switches_to_codex(self):
        result = self.run_provider({"WORK_WIKI_SYNTH_PROVIDER": "codex"})
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "codex")

    def test_job_env_overrides_global_env(self):
        result = self.run_provider(
            {"WORK_WIKI_SYNTH_PROVIDER": "codex", "WORK_WIKI_SLACK_SYNTH_PROVIDER": "claude"}
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "claude")

    def test_invalid_provider_fails_clearly(self):
        result = self.run_provider({"WORK_WIKI_SYNTH_PROVIDER": "bogus"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unknown synth provider", result.stderr)


if __name__ == "__main__":
    unittest.main()
