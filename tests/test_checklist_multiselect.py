"""Exercise production checklist controls against asynchronous host boundaries."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class ChecklistMultiselectTests(unittest.TestCase):
    def test_multiselect_ui_contracts(self):
        executable = os.environ.get("LUAU_BIN") or shutil.which("luau")
        if not executable:
            self.skipTest("Set LUAU_BIN to a Luau CLI executable")
        harness = (ROOT / "tests/checklist_multiselect_runtime.luau").read_text("utf-8")
        harness = harness.replace(
            "-- INJECT checklist\n", (ROOT / "checklist.luau").read_text("utf-8") + "\n"
        )
        with tempfile.TemporaryDirectory(prefix="spider-checklist-multiselect-") as temp:
            script = Path(temp) / "runtime.luau"
            script.write_text(harness, encoding="utf-8")
            result = subprocess.run(
                [executable, str(script)], capture_output=True, encoding="utf-8",
                errors="replace", timeout=20,
            )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS checklist multiselect UI contracts", result.stdout)


if __name__ == "__main__":
    unittest.main()
