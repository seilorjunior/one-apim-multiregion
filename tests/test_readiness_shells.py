"""Verify standalone shell JSON framing and exit propagation without Azure."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from test_reliability import BASH, PWSH, ROOT


@unittest.skipUnless(BASH and PWSH, "Both shells are required")
class ReadinessShellTests(unittest.TestCase):
    def test_json_is_single_object_on_success_and_failure_in_both_shells(self):
        with tempfile.TemporaryDirectory(prefix="lab-report-shell-") as directory:
            root = Path(directory)
            for shell, extension in (("powershell", "ps1"), ("bash", "sh")):
                target = root / "scripts" / shell
                target.mkdir(parents=True)
                shutil.copy(ROOT / "scripts" / shell / f"Test-Readiness.{extension}", target)
                common = target / f"Lab.Common.{extension}"
                if shell == "bash":
                    shutil.copy(ROOT / "scripts" / shell / common.name, common)
                else:
                    common.write_text("", encoding="utf-8")
            engine = root / "scripts" / "lab_readiness.py"
            engine.write_text(
                "import json, os, sys\n"
                "print('START: simulated provider gate', file=sys.stderr)\n"
                "code = int(os.environ['REPORT_EXIT'])\n"
                "print(json.dumps({'status': 'failed' if code else 'passed', 'arguments': sys.argv[1:]}))\n"
                "sys.exit(code)\n", encoding="utf-8",
            )
            for code in (0, 1):
                env = dict(os.environ, REPORT_EXIT=str(code))
                commands = [
                    [PWSH, "-NoProfile", "-File", str(root / "scripts" / "powershell" / "Test-Readiness.ps1"),
                     "-Json", "-StartResources", "-Stage", "Infrastructure", "-WaitSeconds", "60"],
                    [BASH, "-c",
                     'az() { :; }; azd() { :; }; export -f az azd; bash "$1" --json --start-resources --stage Infrastructure --wait-seconds 60',
                     "--", (root / "scripts" / "bash" / "Test-Readiness.sh").as_posix()],
                ]
                for command in commands:
                    with self.subTest(shell=command[0], code=code):
                        result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=30)
                        self.assertEqual(result.returncode, code, result.stderr)
                        report = json.loads(result.stdout)
                        self.assertEqual(report["status"], "failed" if code else "passed")
                        self.assertIn("START: simulated", result.stderr)
                        self.assertIn("--start-resources", report["arguments"])
                        self.assertIn("--private-check-shell", report["arguments"])
                        self.assertIn("Infrastructure", report["arguments"])
                        self.assertIn("60", report["arguments"])


if __name__ == "__main__":
    unittest.main()
