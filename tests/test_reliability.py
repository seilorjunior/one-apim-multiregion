"""Shared offline contracts for PowerShell/Bash rollout and origin evidence."""
import copy
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASH = shutil.which("bash")
if os.name == "nt" and Path(r"C:\Program Files\Git\bin\bash.exe").exists():
    BASH = r"C:\Program Files\Git\bin\bash.exe"
PWSH = shutil.which("pwsh")
HOSTS = ("primary.regional.azure-api.net", "secondary.regional.azure-api.net")
SINCE = "2026-11-03T18:05:00Z"
NOW = "2026-11-03T18:12:30Z"


def metrics():
    return {"value": [{
        "name": {"value": "OriginHealthPercentage"}, "errorCode": "Success",
        "timeseries": [{
            "metadatavalues": [
                {"name": {"value": "Origin"}, "value": host + ":443"},
                {"name": {"value": "OriginGroup"}, "value": "regional-apis"},
            ],
            "data": [
                {"timeStamp": "2026-11-03T18:10:00Z", "minimum": 100},
                {"timeStamp": "2026-11-03T18:11:00Z", "minimum": 100},
            ],
        } for host in HOSTS],
    }]}


@unittest.skipUnless(BASH and PWSH, "Both Bash and PowerShell are required for parity checks")
class ReliabilityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="lab-reliability-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)

    def run_origins(self, data, since=SINCE, now=NOW, hosts=HOSTS, group="regional-apis"):
        fixture = self.directory / "metrics.json"
        fixture.write_text(json.dumps(data), encoding="utf-8")
        ps = r'''
param($Common, $Fixture, $Since, $Now, $PrimaryHost, $SecondaryHost, $Group)
. $Common
$data = Get-Content -LiteralPath $Fixture -Raw | ConvertFrom-Json
$result = Test-LabOriginMetrics $data @($PrimaryHost, $SecondaryHost) ([DateTimeOffset] $Since) ([DateTimeOffset] $Now) $Group
$result | ConvertTo-Json -Depth 10 -Compress
'''
        script = self.directory / "test.ps1"
        script.write_text(ps, encoding="utf-8")
        outputs = []
        commands = [
            [PWSH, "-NoProfile", "-File", str(script),
             str(ROOT / "scripts" / "powershell" / "Lab.Common.ps1"), str(fixture), since, now, *hosts, group],
            [BASH, "-c", '''
source "$1"
LAB_ENV[APIM_PRIMARY_HOST]=primary.regional.azure-api.net
LAB_ENV[APIM_SECONDARY_HOST]=secondary.regional.azure-api.net
LAB_ENV[FRONT_DOOR_PRIMARY_ORIGIN_HOST]="$5"
LAB_ENV[FRONT_DOOR_SECONDARY_ORIGIN_HOST]="$6"
LAB_ENV[FRONT_DOOR_ORIGIN_GROUP]="$7"
lab_origin_evidence "$(< "$2")" "$3" "$4"
''', "--", (ROOT / "scripts" / "bash" / "Lab.Common.sh").as_posix(), fixture.as_posix(), since, now, *hosts, group],
        ]
        for command in commands:
            result = subprocess.run(command, capture_output=True, text=True, timeout=30)
            if result.returncode:
                outputs.append(False)
            else:
                body = json.loads(result.stdout)
                outputs.append(body.get("Healthy", body.get("status") == "healthy"))
        self.assertEqual(outputs[0], outputs[1], f"Shell behavior differs: {outputs}")
        return outputs[0]

    def test_both_origins_require_two_recent_complete_healthy_buckets(self):
        self.assertTrue(self.run_origins(metrics()))

    def test_private_ingress_requires_private_gateway_hosts_and_group(self):
        hosts = ("gw-westus3.owned-domain.org", "gw-centralus.owned-domain.org")
        group = "regional-apis-private"
        self.assertFalse(self.run_origins(metrics(), hosts=hosts, group=group))
        private = metrics()
        for series, host in zip(private["value"][0]["timeseries"], hosts):
            series["metadatavalues"][0]["value"] = host + ":443"
            series["metadatavalues"][1]["value"] = group
        self.assertTrue(self.run_origins(private, hosts=hosts, group=group))
        self.assertFalse(self.run_origins(private, hosts=hosts))
        self.assertFalse(self.run_origins(private, group=group))

    def test_missing_stale_unhealthy_null_partial_and_gapped_evidence_fail(self):
        fixtures = {}
        missing = metrics()
        missing["value"][0]["timeseries"].pop()
        fixtures["missing-origin"] = missing
        stale = metrics()
        for series in stale["value"][0]["timeseries"]:
            series["data"][0]["timeStamp"] = "2026-11-03T18:05:00Z"
            series["data"][1]["timeStamp"] = "2026-11-03T18:06:00Z"
        fixtures["stale"] = stale
        for value in (None, 99.99, 0, "100", True, 101):
            unhealthy = metrics()
            unhealthy["value"][0]["timeseries"][1]["data"][1]["minimum"] = value
            fixtures[f"value-{value}"] = unhealthy
        partial = metrics()
        partial["value"][0]["timeseries"][1]["data"][1]["timeStamp"] = "2026-11-03T18:12:00Z"
        fixtures["partial-bucket"] = partial
        gap = metrics()
        gap["value"][0]["timeseries"][1]["data"][0]["timeStamp"] = "2026-11-03T18:09:00Z"
        fixtures["gap"] = gap
        wrong_group = metrics()
        wrong_group["value"][0]["timeseries"][1]["metadatavalues"][1]["value"] = "another-group"
        fixtures["wrong-group"] = wrong_group
        empty = metrics()
        empty["value"][0]["timeseries"][1]["data"] = []
        fixtures["empty"] = empty
        duplicate = metrics()
        duplicate["value"][0]["timeseries"].append(copy.deepcopy(duplicate["value"][0]["timeseries"][0]))
        fixtures["duplicate-series"] = duplicate
        error = metrics()
        error["value"][0]["errorCode"] = "Forbidden"
        fixtures["metric-error"] = error
        for name, fixture in fixtures.items():
            with self.subTest(name=name):
                self.assertFalse(self.run_origins(fixture))

    def test_recovery_boundary_excludes_pre_restoration_and_overlapping_buckets(self):
        self.assertFalse(self.run_origins(metrics(), since="2026-11-03T18:10:01Z"))
        self.assertFalse(self.run_origins(metrics(), since="2026-11-03T18:10:00.001Z"))
        self.assertFalse(self.run_origins(metrics(), since="2026-11-03T18:11:00Z"))
        self.assertTrue(self.run_origins(metrics(), now="2026-11-03T18:16:00Z"))
        self.assertFalse(self.run_origins(metrics(), now="2026-11-03T18:16:00.001Z"))

    def test_rollout_hashes_are_stable_cross_shell_and_change_for_config_or_tls(self):
        tls = self.directory / "tls"
        tls.mkdir()
        certificate = tls / "tls.crt"
        key = tls / "tls.key"
        certificate.write_text("test-certificate", encoding="utf-8")
        key.write_text("test-key", encoding="utf-8")
        project = self.directory / "project"
        workload = project / "src" / "lab-api"
        workload.mkdir(parents=True)
        template = workload / "workload.yaml"
        original = (ROOT / "src" / "lab-api" / "workload.yaml").read_text(encoding="utf-8")
        ps_script = self.directory / "manifest.ps1"
        ps_script.write_text(r'''
param($Common, $Template, $Tls)
. $Common
$region = [pscustomobject]@{ Location='westus3'; Cluster='aks-primary'; BackendIp='10.10.2.10'; ApimSubnet='10.10.0.0/26' }
New-LabManifest $Template $Tls $region
''', encoding="utf-8")

        def hashes(text):
            template.write_bytes(text.encode("utf-8"))
            commands = [
                [PWSH, "-NoProfile", "-File", str(ps_script),
                 str(ROOT / "scripts" / "powershell" / "Lab.Common.ps1"), str(template), str(tls)],
                [BASH, "-c", '''
source "$1"
LAB_ROOT="$2"
LAB_LOCATION=westus3 LAB_CLUSTER=aks-primary LAB_BACKEND_IP=10.10.2.10 LAB_APIM_SUBNET=10.10.0.0/26
lab_manifest "$3"
''', "--", (ROOT / "scripts" / "bash" / "Lab.Common.sh").as_posix(), project.as_posix(), tls.as_posix()],
            ]
            result_hashes = []
            for command in commands:
                result = subprocess.run(command, capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotRegex(result.stdout, r"__[A-Z_]+__")
                match = re.search(r'checksum/lab-workload: "([a-f0-9]{64})"', result.stdout)
                self.assertIsNotNone(match)
                result_hashes.append(match[1])
            self.assertEqual(result_hashes[0], result_hashes[1])
            return result_hashes[0]

        first = hashes(original)
        self.assertEqual(first, hashes(original))
        self.assertEqual(first, hashes(original.replace("\n", "\r\n")))
        self.assertNotEqual(first, hashes(original.replace("server_tokens off;", "server_tokens on;")))
        certificate.write_text("rotated-certificate", encoding="utf-8")
        rotated = hashes(original)
        self.assertNotEqual(first, rotated)
        key.write_text("rotated-private-key", encoding="utf-8")
        self.assertNotEqual(rotated, hashes(original))


if __name__ == "__main__":
    unittest.main()
