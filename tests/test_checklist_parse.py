"""Run the production Markdown checklist parser with the Luau CLI."""

import os
from pathlib import Path
import shutil
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]


class ChecklistParseTests(unittest.TestCase):
    def test_markdown_reply_into_checklist(self):
        executable = os.environ.get("LUAU_BIN") or shutil.which("luau")
        if not executable:
            self.skipTest("Set LUAU_BIN to a Luau CLI executable")
        result = subprocess.run(
            [executable, str(ROOT / "tests" / "checklist_parse_runtime.luau")],
            cwd=ROOT,
            capture_output=True,
            encoding="utf-8",
            errors="replace",
            timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
