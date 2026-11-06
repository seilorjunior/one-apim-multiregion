"""Verify authorization, prerequisite gates and k6 exit propagation without traffic."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from test_reliability import BASH, PWSH, ROOT


@unittest.skipUnless(BASH and PWSH, "Both shells are required")
class LoadShellTests(unittest.TestCase):
    def test_both_shells_gate_traffic_and_propagate_failures(self):
        with tempfile.TemporaryDirectory(prefix="lab-load-shell-") as directory:
            root = Path(directory)
            for shell, extension in (("powershell", "ps1"), ("bash", "sh")):
                target = root / shell
                target.mkdir()
                script = target / f"Test-Load.{extension}"
                shutil.copy(ROOT / "scripts" / shell / script.name, script)
                common = target / f"Lab.Common.{extension}"
                if shell == "powershell":
                    common.write_text(r'''
$ErrorActionPreference = 'Stop'
function Get-LabEnvironment {
    return @{API_URL='https://example.invalid/lab'; AZURE_PRIMARY_LOCATION='westus3'; AZURE_SECONDARY_LOCATION='centralus'}
}
function Assert-LabValues {}
function Invoke-LabReadiness {
    param($Values, $Stage)
    if ($Stage -ne 'Workloads') { throw 'Incorrect readiness stage' }
    if ($env:READY_EXIT -ne '0') { throw 'Prerequisites failed' }
}
function k6 {
    @($args) | ConvertTo-Json | Set-Content $env:LOAD_CALL
    $global:LASTEXITCODE = [int]$env:LOAD_EXIT
}
''', encoding="utf-8")
                else:
                    common.write_text(r'''
set -euo pipefail
LAB_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
declare -A LAB_ENV=([API_URL]=https://example.invalid/lab [AZURE_PRIMARY_LOCATION]=westus3 [AZURE_SECONDARY_LOCATION]=centralus)
lab_error() { echo "$*" >&2; }
lab_range() { [[ "$2" =~ ^[0-9]+$ ]] && (( $2 >= $3 && $2 <= $4 )); }
lab_require_tools() { :; }
lab_load_environment() { :; }
lab_assert_values() { :; }
lab_confirm() { [[ "$2" == true ]]; }
lab_readiness() { [[ "$1" == Workloads && "$READY_EXIT" == 0 ]]; }
k6() { printf '%s\n' "$@" > "$LOAD_CALL"; return "$LOAD_EXIT"; }
''', encoding="utf-8")
                for case, ready_code, load_code, what_if in (
                        ("preview", 0, 0, True), ("success", 0, 0, False),
                        ("k6 failure", 0, 99, False), ("readiness failure", 1, 0, False)):
                    marker = root / f"{shell}-call.json"
                    marker.unlink(missing_ok=True)
                    env = dict(os.environ, READY_EXIT=str(ready_code), LOAD_EXIT=str(load_code),
                               LOAD_CALL=str(marker))
                    summary = root / shell / "results" / "summary.json"
                    if shell == "powershell":
                        command = [PWSH, "-NoProfile", "-File", str(script),
                                   "-SummaryPath", str(summary), "-DurationSeconds", "5",
                                   "-WhatIf" if what_if else "-Confirm:$false"]
                    else:
                        command = [BASH, script.as_posix(), "--summary-path", summary.as_posix(),
                                   "--duration-seconds", "5", "--what-if" if what_if else "--yes"]
                    with self.subTest(shell=shell, case=case):
                        result = subprocess.run(command, env=env, capture_output=True, text=True,
                                                timeout=30, cwd=root)
                        self.assertEqual(result.returncode == 0, case in ("preview", "success"),
                                         result.stdout + result.stderr)
                        self.assertEqual(marker.exists(), case in ("success", "k6 failure"))
                        if marker.exists():
                            args = (json.loads(marker.read_text(encoding="utf-8-sig"))
                                    if shell == "powershell" else marker.read_text().splitlines())
                            for expected in ("--no-usage-report", "CONFIRM_LOAD=yes",
                                             "LOAD_SECONDS=5", "PRIMARY_REGION=westus3"):
                                self.assertIn(expected, args)


if __name__ == "__main__":
    unittest.main()
