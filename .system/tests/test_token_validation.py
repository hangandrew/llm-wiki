#!/usr/bin/env python3
"""Tests for the credential validation + storage helpers in install.sh.

Rather than run the whole installer, we extract the relevant bash functions
(secrets_set/secrets_has/validate_*/maybe_store_secret) and exercise them with a
fake `curl` on PATH that returns canned API responses. This keeps the test
hermetic and offline while still running the real shell code.
"""
import os
import shutil
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
INSTALL = ROOT / "install.sh"

HARNESS = textwrap.dedent(
    """
    set -uo pipefail
    src() { sed -n "/^$1() {/,/^}/p" "$INSTALL"; }
    eval "$(src secrets_set)"
    eval "$(src secrets_has)"
    eval "$(src validate_slack_token)"
    eval "$(src validate_granola_key)"
    eval "$(src maybe_store_secret)"
    VALIDATION_DETAIL=""
    maybe_store_secret "$KEY" "$VALUE" "$LABEL" "$VALIDATOR"
    """
)

FAKE_CURL = textwrap.dedent(
    """\
    #!/usr/bin/env bash
    case "${FAKE_MODE:-}" in
      slack-ok)    echo '{"ok":true,"user":"u","team":"t"}' ;;
      slack-bad)   echo '{"ok":false,"error":"invalid_auth"}' ;;
      slack-rate)  echo '{"ok":false,"error":"ratelimited"}' ;;
      granola-ok)  echo "200" ;;
      granola-bad) echo "401" ;;
      granola-5xx) echo "503" ;;
      netfail)     exit 7 ;;
      *)           echo "FAKE_CURL: unknown mode '${FAKE_MODE:-}'" >&2; exit 99 ;;
    esac
    """
)


class TokenValidationTests(unittest.TestCase):
    def _run(self, *, mode, key, value, label, validator, assume_yes="1", skip=None, with_curl=True):
        with tempfile.TemporaryDirectory() as td:
            tdp = Path(td)
            secrets = tdp / "secrets.env"
            fakebin = tdp / "bin"
            fakebin.mkdir()
            if with_curl:
                curl = fakebin / "curl"
                curl.write_text(FAKE_CURL)
                curl.chmod(curl.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)

            env = {
                **os.environ,
                "INSTALL": str(INSTALL),
                "SECRETS_FILE": str(secrets),
                "ASSUME_YES": assume_yes,
                "KEY": key,
                "VALUE": value,
                "LABEL": label,
                "VALIDATOR": validator,
                "FAKE_MODE": mode,
            }
            if skip is not None:
                env["WORK_WIKI_SKIP_TOKEN_CHECK"] = skip
            if with_curl:
                env["PATH"] = f"{fakebin}:{os.environ['PATH']}"
                bash = "bash"
            else:
                # Isolate PATH to a dir with the tools the code needs but NO curl,
                # so `command -v curl` fails. Symlink the real tools in.
                for tool in ("sed", "mkdir", "mktemp", "chmod", "mv", "python3"):
                    real = shutil.which(tool)
                    if real:
                        (fakebin / tool).symlink_to(real)
                env["PATH"] = str(fakebin)
                bash = shutil.which("bash") or "/bin/bash"

            result = subprocess.run(
                [bash, "-c", HARNESS],
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )
            stored = secrets.read_text() if secrets.exists() else ""
            return result, stored

    # --- Slack ---
    def test_slack_valid_token_is_stored(self):
        result, stored = self._run(
            mode="slack-ok", key="WORK_WIKI_SLACK_TOKEN", value="xoxp-good",
            label="Slack token", validator="validate_slack_token",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("validated", result.stdout)
        self.assertIn("WORK_WIKI_SLACK_TOKEN=xoxp-good", stored)

    def test_slack_rejected_token_is_not_stored(self):
        result, stored = self._run(
            mode="slack-bad", key="WORK_WIKI_SLACK_TOKEN", value="xoxp-bad",
            label="Slack token", validator="validate_slack_token",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("REJECTED", result.stderr)
        self.assertNotIn("xoxp-bad", stored)

    def test_slack_ratelimit_stores_with_warning(self):
        result, stored = self._run(
            mode="slack-rate", key="WORK_WIKI_SLACK_TOKEN", value="xoxp-rl",
            label="Slack token", validator="validate_slack_token",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Could not verify", result.stderr)
        self.assertIn("WORK_WIKI_SLACK_TOKEN=xoxp-rl", stored)

    # --- Granola ---
    def test_granola_valid_key_is_stored(self):
        result, stored = self._run(
            mode="granola-ok", key="WORK_WIKI_GRANOLA_API_KEY", value="grn-good",
            label="Granola key", validator="validate_granola_key",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("WORK_WIKI_GRANOLA_API_KEY=grn-good", stored)

    def test_granola_rejected_key_is_not_stored(self):
        result, stored = self._run(
            mode="granola-bad", key="WORK_WIKI_GRANOLA_API_KEY", value="grn-revoked",
            label="Granola key", validator="validate_granola_key",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("REJECTED", result.stderr)
        self.assertNotIn("grn-revoked", stored)

    def test_granola_5xx_stores_with_warning(self):
        result, stored = self._run(
            mode="granola-5xx", key="WORK_WIKI_GRANOLA_API_KEY", value="grn-flaky",
            label="Granola key", validator="validate_granola_key",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Could not verify", result.stderr)
        self.assertIn("WORK_WIKI_GRANOLA_API_KEY=grn-flaky", stored)

    # --- Cross-cutting ---
    def test_network_failure_stores_with_warning(self):
        result, stored = self._run(
            mode="netfail", key="WORK_WIKI_SLACK_TOKEN", value="xoxp-net",
            label="Slack token", validator="validate_slack_token",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Could not verify", result.stderr)
        self.assertIn("WORK_WIKI_SLACK_TOKEN=xoxp-net", stored)

    def test_skip_check_stores_without_calling_curl(self):
        # Mode is 'slack-bad' but skipping should bypass validation entirely.
        result, stored = self._run(
            mode="slack-bad", key="WORK_WIKI_SLACK_TOKEN", value="xoxp-skip",
            label="Slack token", validator="validate_slack_token", skip="1",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Skipping", result.stdout)
        self.assertIn("WORK_WIKI_SLACK_TOKEN=xoxp-skip", stored)

    def test_missing_curl_stores_unverified(self):
        result, stored = self._run(
            mode="slack-bad", key="WORK_WIKI_SLACK_TOKEN", value="xoxp-nocurl",
            label="Slack token", validator="validate_slack_token", with_curl=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("curl not found", result.stdout)
        self.assertIn("WORK_WIKI_SLACK_TOKEN=xoxp-nocurl", stored)

    def test_blank_value_is_noop(self):
        result, stored = self._run(
            mode="slack-ok", key="WORK_WIKI_SLACK_TOKEN", value="",
            label="Slack token", validator="validate_slack_token",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(stored, "")


if __name__ == "__main__":
    unittest.main()
