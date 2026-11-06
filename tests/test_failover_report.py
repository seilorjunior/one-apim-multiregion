"""Offline tests for durable, sanitized failover observer evidence."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import time
import unittest
from unittest import mock
import uuid

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("failover_report", ROOT / "scripts" / "failover_report.py")
REPORT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REPORT)


class FailoverReportTests(unittest.TestCase):
    def setUp(self):
        self.directory = ROOT / ".artifacts" / "failover-report-tests" / str(uuid.uuid4())
        self.directory.mkdir(parents=True)
        self.addCleanup(shutil.rmtree, self.directory)
        self.path = self.directory / "report.json"
        self.command("init", "private", "Primary", "westus3", "Secondary", "centralus", "600")

    def command(self, *args):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            REPORT.main([*args, "--path", str(self.path)])

    def report(self):
        return json.loads(self.path.read_text())

    def test_failure_retains_all_independent_cleanup_states(self):
        self.command("stage", "availability", "running")
        self.command("stage", "restoration", "failed")
        self.command("replicas", "restored", "0")
        self.command("finish", "1")
        report = self.report()
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["evidence"], "NotProven")
        self.assertEqual(report["stages"]["availability"]["status"], "failed")
        self.assertEqual(report["stages"]["restoration"]["status"], "failed")
        self.assertEqual(report["stages"]["recoveryOrigins"]["status"], "notRun")
        self.assertEqual(report["replicas"]["restored"], 0)
        self.assertIsNotNone(report["completedAtUtc"])

    def test_success_needs_every_stage_not_only_an_exit_code(self):
        self.command("finish", "0")
        self.assertEqual(self.report()["status"], "failed")
        self.assertEqual(self.report()["exitCode"], 1)

    def test_samples_are_bounded_and_untrusted_fields_are_not_retained(self):
        for _ in range(REPORT.SAMPLE_LIMIT + 2):
            self.command("sample", "baseline", REPORT.now(), str(time.monotonic()), "200",
                         "sensitive-unexpected-response-body", "invalidResponse")
        report = self.report()
        self.assertEqual(report["sampleCount"], REPORT.SAMPLE_LIMIT + 2)
        self.assertEqual(len(report["samples"]), REPORT.SAMPLE_LIMIT)
        self.assertTrue(report["samplesTruncated"])
        self.assertEqual(report["failedSampleCount"], REPORT.SAMPLE_LIMIT + 2)
        self.assertNotIn("sensitive-unexpected", self.path.read_text())

    def test_existing_report_is_preserved(self):
        before = self.path.read_bytes()
        with self.assertRaises(SystemExit):
            self.command("init", "private", "Primary", "westus3", "Secondary", "centralus", "600")
        self.assertEqual(self.path.read_bytes(), before)

    def test_interrupt_never_reports_success(self):
        self.command("stage", "disruption", "running")
        self.command("finish", "130")
        self.assertEqual(self.report()["status"], "interrupted")
        self.assertEqual(self.report()["stages"]["disruption"]["status"], "failed")
        self.assertNotIn("disruptionStartMonotonicSeconds", self.report()["timing"])

    def test_invalid_error_categories_cannot_store_raw_errors(self):
        before = self.path.read_bytes()
        with self.assertRaises(SystemExit):
            self.command("sample", "baseline", REPORT.now(), str(time.monotonic()), "200",
                         "westus3", "raw secret-bearing exception")
        self.assertEqual(self.path.read_bytes(), before)

    def test_atomic_save_retries_transient_windows_file_locks(self):
        replace = Path.replace
        attempts = 0

        def transient_lock(source, destination):
            nonlocal attempts
            attempts += 1
            if attempts < 3:
                raise PermissionError("Simulated scanner lock")
            return replace(source, destination)

        with mock.patch.object(Path, "replace", transient_lock), mock.patch.object(REPORT.time, "sleep"):
            self.command("finish", "1")
        self.assertEqual(attempts, 3)
        self.assertEqual(self.report()["status"], "failed")


if __name__ == "__main__":
    unittest.main()
