"""Portable evidence-contract tests; never native lifecycle acceptance."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("lifecycle", Path(__file__).parents[1] / "test_ios_lifecycle_behavior.py")
HARNESS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HARNESS)


class EvidenceContract(unittest.TestCase):
    def test_failed_child_keeps_stdout_stderr_and_exit(self):
        self.assertTrue(hasattr(HARNESS, "run_recorded"), "failed native evidence must survive TemporaryDirectory cleanup")
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            with self.assertRaises(subprocess.CalledProcessError):
                HARNESS.run_recorded([sys.executable, "-c", "import sys; print('child-out'); print('child-err', file=sys.stderr); sys.exit(7)"], out, "behavior", timeout=5)
            self.assertIn("child-out", (out / "behavior.stdout.txt").read_text())
            self.assertIn("child-err", (out / "behavior.stderr.txt").read_text())
            self.assertEqual(json.loads((out / "behavior.result.json").read_text())["returncode"], 7)


    def test_timeout_keeps_partial_output(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            with self.assertRaises(subprocess.TimeoutExpired):
                HARNESS.run_recorded([sys.executable, "-c", "import time; print('before-timeout', flush=True); time.sleep(10)"], out, "timeout", timeout=1)
            self.assertIn("before-timeout", (out / "timeout.stdout.txt").read_text())
            self.assertEqual(json.loads((out / "timeout.result.json").read_text())["error"], "TimeoutExpired")

    def test_missing_executable_is_not_success(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            with self.assertRaises(OSError):
                HARNESS.run_recorded([str(out / "missing-executable")], out, "missing", timeout=1)
            self.assertEqual(json.loads((out / "missing.result.json").read_text())["error"], "FileNotFoundError")

    def test_success_keeps_real_output(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            HARNESS.run_recorded([sys.executable, "-c", "print('real-success')"], out, "success", timeout=5)
            self.assertEqual(json.loads((out / "success.result.json").read_text())["returncode"], 0)
            self.assertIn("real-success", (out / "success.stdout.txt").read_text())

    def test_each_wait_has_unique_stage_and_original_budgets(self):
        import re
        fixture = (Path(__file__).parent / "ios_lifecycle_main.swift").read_text()
        labels = re.findall(r'wait\("([^"]+)"\)', fixture)
        self.assertEqual(len(labels), 7)
        self.assertEqual(len(labels), len(set(labels)))
        self.assertNotRegex(fixture, r'wait\s*\{')
        self.assertIn("addingTimeInterval(5)", fixture)
        self.assertIn("Thread.sleep(forTimeInterval: 31)", fixture)
        self.assertIn("timeout=60", Path(HARNESS.__file__).read_text())
        self.assertIn("timeout=55", Path(HARNESS.__file__).read_text())


if __name__ == "__main__":
    unittest.main(verbosity=2)
