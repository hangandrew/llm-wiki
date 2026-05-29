import importlib.util
import json
import sys
import tempfile
import tomllib
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "codex_config_instructions",
    ROOT / "scripts/codex-config-instructions.py",
)
codex_config = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = codex_config
SPEC.loader.exec_module(codex_config)


MARKER = "<!-- work-wiki -->"
BLOCK = f"## Work Wiki {MARKER}\n\nRead `/tmp/work-wiki/wiki/README.md`."


class CodexConfigInstructionsTest(unittest.TestCase):
    def write_config(self, text: str) -> Path:
        self.tmp = tempfile.TemporaryDirectory()
        path = Path(self.tmp.name) / "config.toml"
        path.write_text(text)
        return path

    def tearDown(self):
        if hasattr(self, "tmp"):
            self.tmp.cleanup()

    def parsed(self, path: Path):
        return tomllib.loads(path.read_text())

    def test_install_adds_missing_key_at_top_level_before_tables(self):
        path = self.write_config(
            'model = "gpt-5.5"\n\n[features]\ngoals = true\n'
        )

        codex_config.install(path, BLOCK, MARKER)

        parsed = self.parsed(path)
        self.assertIn(MARKER, parsed["developer_instructions"])
        self.assertNotIn("developer_instructions", parsed["features"])
        self.assertLess(path.read_text().index("developer_instructions"), path.read_text().index("[features]"))

    def test_install_repairs_previously_misplaced_work_wiki_block(self):
        path = self.write_config(
            '[features]\ngoals = true\ndeveloper_instructions = "## Work Wiki <!-- work-wiki -->\\nold"\n'
        )

        codex_config.install(path, BLOCK, MARKER)

        parsed = self.parsed(path)
        self.assertIn(MARKER, parsed["developer_instructions"])
        self.assertNotIn("developer_instructions", parsed["features"])

    def test_install_preserves_existing_top_level_instructions(self):
        path = self.write_config(
            'developer_instructions = "Keep this."\n\n[features]\ngoals = true\n'
        )

        codex_config.install(path, BLOCK, MARKER)

        value = self.parsed(path)["developer_instructions"]
        self.assertIn("Keep this.", value)
        self.assertIn(MARKER, value)

    def test_uninstall_removes_work_wiki_block_and_leaves_other_instructions(self):
        value = f"Keep this.\n\n{BLOCK}"
        path = self.write_config(
            "developer_instructions = " + json.dumps(value) + "\n\n[features]\ngoals = true\n"
        )

        codex_config.uninstall(path, MARKER)

        parsed = self.parsed(path)
        self.assertEqual(parsed["developer_instructions"], "Keep this.")
        self.assertEqual(parsed["features"]["goals"], True)


if __name__ == "__main__":
    unittest.main()
