"""Run visibility lifecycle regressions against the production Luau modules."""

from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class VisibilityRuntimeTests(unittest.TestCase):
    def test_minimize_and_restore(self):
        executable = os.environ.get("LUAU_BIN") or shutil.which("luau")
        if not executable:
            self.skipTest("Set LUAU_BIN to a Luau CLI executable")
        harness = (ROOT / "tests" / "visibility_runtime.luau").read_text("utf-8")
        for name in ("radar", "pet"):
            harness = harness.replace(
                f"-- INJECT {name}", (ROOT / f"{name}.luau").read_text("utf-8")
            )
        entry = (ROOT / "init.luau").read_text("utf-8")
        wallpaper = entry[entry.index("local STEP_X, STEP_Y"):entry.index("-- 2. Composer")]
        harness = harness.replace("-- INJECT wallpaper", wallpaper)
        with tempfile.TemporaryDirectory(prefix="spider-visibility-tests-") as temp:
            script = Path(temp) / "runtime.luau"
            script.write_text(harness, encoding="utf-8")
            result = subprocess.run(
                [executable, str(script)], capture_output=True, encoding="utf-8",
                errors="replace", timeout=20,
            )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS visibility lifecycle scenarios", result.stdout)


if __name__ == "__main__":
    unittest.main()
