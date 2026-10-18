"""The upstream comparison must reject incomplete or crashed test runs."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/sync-upstream.sh"


@unittest.skipUnless(os.name != "nt" and shutil.which("bash"), "macOS/Linux shell tooling")
class SyncSuiteCompletionTests(unittest.TestCase):
    def run_suite(self, output, status):
        source = SCRIPT.read_text(encoding="utf-8")
        functions = source[source.index("failures() {"):source.index("run_tests() {")]
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            interpreter = directory / "python3"
            interpreter.write_text(
                "#!/bin/sh\ncat <<'SUITE_OUTPUT'\n" + output
                + f"\nSUITE_OUTPUT\nexit {status}\n", encoding="utf-8")
            interpreter.chmod(0o755)
            environment = dict(os.environ, PATH=tmp + os.pathsep + os.environ.get("PATH", ""))
            return subprocess.run(
                ["bash", "-c", functions + '\nrun_full_suite "$1" "$2"',
                 "sync-check", tmp, str(directory / "suite.log")],
                env=environment, capture_output=True, text=True, encoding="utf-8")

    def test_completed_success_is_accepted(self):
        self.assertEqual(self.run_suite("Ran 12 tests in 0.1s\n\nOK", 0).returncode, 0)

    def test_completed_named_failure_can_be_compared_with_baseline(self):
        output = "FAIL: test_example (Example)\nRan 12 tests in 0.1s\n\nFAILED (failures=1)"
        self.assertEqual(self.run_suite(output, 1).returncode, 0)

    def test_import_crash_is_rejected(self):
        result = self.run_suite("ModuleNotFoundError: No module named dependency", 1)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("全套测试未正常完成", result.stderr)

    def test_interruption_after_a_failure_is_rejected(self):
        self.assertNotEqual(self.run_suite("FAIL: test_example (Example)", 137).returncode, 0)

    def test_success_text_with_abnormal_exit_is_rejected(self):
        self.assertNotEqual(self.run_suite("Ran 12 tests in 0.1s\n\nOK", 137).returncode, 0)

    def test_named_failure_with_abnormal_exit_is_rejected(self):
        output = "FAIL: test_example (Example)\nRan 12 tests in 0.1s\n\nFAILED (failures=1)"
        self.assertNotEqual(self.run_suite(output, 137).returncode, 0)

    def test_empty_discovery_is_rejected(self):
        self.assertNotEqual(self.run_suite("Ran 0 tests in 0.0s\n\nOK", 0).returncode, 0)


if __name__ == "__main__":
    unittest.main()
