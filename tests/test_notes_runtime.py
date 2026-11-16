"""Run production Luau note modules against a deterministic host boundary.

Install Luau CLI separately, then set LUAU_BIN or put luau on PATH.
Only UI/state/async host interfaces are mocked; module bodies are loaded verbatim.
"""

from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class NotesRuntimeTests(unittest.TestCase):
    def test_async_and_ui_contracts(self):
        executable = os.environ.get("LUAU_BIN") or shutil.which("luau")
        if not executable:
            self.skipTest("Set LUAU_BIN to a Luau CLI executable")
        harness = (ROOT / "tests" / "notes_runtime.luau").read_text(encoding="utf-8")
        for name in ("notes_store", "toolbar_button", "notes", "db", "prompts"):
            source = (ROOT / f"{name}.luau").read_text(encoding="utf-8")
            harness = harness.replace(f"-- INJECT {name}", source)
        with tempfile.TemporaryDirectory(prefix="spider-notes-tests-") as temp:
            script = Path(temp) / "runtime.luau"
            script.write_text(harness, encoding="utf-8")
            result = subprocess.run(
                [executable, str(script)],
                capture_output=True,
                encoding="utf-8",
                errors="replace",
                timeout=20,
            )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS 15 runtime scenarios", result.stdout)


if __name__ == "__main__":
    unittest.main()
