"""Exercise shared contracts directly, without shell runtimes or Azure access."""
import base64
import contextlib
import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from test_reliability import HOSTS, NOW, ROOT, SINCE, metrics


spec = importlib.util.spec_from_file_location("lab_contracts", ROOT / "scripts" / "lab_contracts.py")
contracts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contracts)


class LabContractTests(unittest.TestCase):
    def private_values(self):
        return {
            "APP_INGRESS_MODE": "private",
            "APP_GATEWAY_DNS_SUFFIX": "owned-domain.org",
            "AZURE_LOCATION": "westus3", "AZURE_SECONDARY_LOCATION": "centralus",
            "APP_GATEWAY_KEY_VAULT_NAME": "test-vault",
            "APP_GATEWAY_KEY_VAULT_RESOURCE_GROUP": "rg-certs",
            "APP_GATEWAY_CERTIFICATE_SECRET_ID": "https://test-vault.vault.azure.net/secrets/gateway/",
        }

    def run_cli(self, arguments, payload=""):
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch("sys.stdin", io.StringIO(payload)), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = contracts.main(arguments)
        return code, stdout.getvalue(), stderr.getvalue()

    def test_ingress_defaults_normalization_and_preservation(self):
        self.assertEqual(contracts.ingress_configuration({}), {
            "APP_INGRESS_MODE": "public",
            "APP_GATEWAY_KEY_VAULT_NETWORK_MODE": "trusted-services",
        })
        values = self.private_values()
        values["APP_GATEWAY_PRIMARY_HOST"] = "CUSTOM.OWNED-DOMAIN.ORG"
        values["UNRELATED_SECRET"] = "do-not-echo"
        original = copy.deepcopy(values)
        result = contracts.ingress_configuration(values)
        self.assertEqual(values, original)
        self.assertEqual(result["APP_GATEWAY_PRIMARY_HOST"], "custom.owned-domain.org")
        self.assertEqual(result["APP_GATEWAY_SECONDARY_HOST"], "gw-centralus.owned-domain.org")
        self.assertEqual(result["APP_GATEWAY_NETWORK_MODE"], "retain")
        self.assertEqual(result["APP_GATEWAY_CERTIFICATE_SECRET_ID"], values["APP_GATEWAY_CERTIFICATE_SECRET_ID"][:-1])
        self.assertNotIn("UNRELATED_SECRET", result)
        self.assertNotIn("do-not-echo", json.dumps(result))

    def test_ingress_rejects_invalid_modes_domains_secrets_and_rollback(self):
        for changes in (
            {"APP_INGRESS_MODE": ""}, {"APP_GATEWAY_NETWORK_MODE": "invalid"},
            {"APP_GATEWAY_KEY_VAULT_NETWORK_MODE": "invalid"},
            {"APP_GATEWAY_PRIMARY_HOST": "gw.example.com"},
            {"APP_GATEWAY_PRIMARY_HOST": "gw.azure-api.net"},
            {"APP_GATEWAY_PRIMARY_HOST": "10.10.3.10"},
            {"APP_GATEWAY_PRIMARY_HOST": "gw-" + "a" * 64 + ".owned-domain.org"},
            {"APP_GATEWAY_PRIMARY_HOST": "gw-centralus.owned-domain.org"},
            {"APP_GATEWAY_CERTIFICATE_SECRET_ID": "https://other-vault.vault.azure.net/secrets/gateway"},
            {"APP_GATEWAY_CERTIFICATE_SECRET_ID": "https://test-vault.vault.azure.net/secrets/gateway/version"},
            {"APP_GATEWAY_KEY_VAULT_RESOURCE_GROUP": " "},
            {"APP_GATEWAY_DNS_SUFFIX": ""},
        ):
            with self.subTest(changes=changes), self.assertRaises(contracts.ContractError):
                contracts.ingress_configuration(self.private_values() | changes)
        with self.assertRaisesRegex(contracts.ContractError, "retain before rollback"):
            contracts.ingress_configuration({"APP_GATEWAY_PRIMARY_ID": "existing-gateway"})
        self.assertEqual(contracts.ingress_configuration({
            "APP_GATEWAY_PRIMARY_ID": "existing-gateway", "APP_GATEWAY_NETWORK_MODE": "retain",
        })["APP_GATEWAY_NETWORK_MODE"], "retain")

    def test_manifest_hash_matches_normalized_rendered_content(self):
        with tempfile.TemporaryDirectory(prefix="lab-contracts-") as directory:
            root = Path(directory)
            (root / "tls.crt").write_bytes(b"certificate")
            (root / "tls.key").write_bytes(b"key")
            template = root / "workload.yaml"
            source = "__REGION__ __CLUSTER__ __BACKEND_IP__ __APIM_SUBNET__\n__TLS_CERTIFICATE__ __TLS_KEY__\n__WORKLOAD_HASH__"
            expected = ("westus3 aks-test 10.10.2.10 10.10.0.0/26\n"
                        f"{base64.b64encode(b'certificate').decode()} {base64.b64encode(b'key').decode()}\n__WORKLOAD_HASH__")
            expected = expected.replace("__WORKLOAD_HASH__", hashlib.sha256(expected.encode()).hexdigest())
            for newline in ("\n", "\r\n", "\r"):
                template.write_bytes(source.replace("\n", newline).encode())
                self.assertEqual(contracts.render_manifest(template, root, "westus3", "aks-test", "10.10.2.10", "10.10.0.0/26"), expected)
            arguments = ["manifest", "--template", str(template), "--tls", str(root),
                         "--region", "westus3", "--cluster", "aks-test", "--ip", "10.10.2.10",
                         "--subnet", "10.10.0.0/26"]
            code, stdout, stderr = self.run_cli(arguments)
            self.assertEqual((code, json.loads(stdout)["manifest"], stderr), (0, expected, ""))
            self.assertEqual(self.run_cli(arguments + ["--text"]), (0, expected, ""))
            template.write_text("__UNKNOWN__")
            code, stdout, stderr = self.run_cli(arguments)
            self.assertEqual((code, stdout), (1, ""))
            self.assertIn("Unresolved workload placeholder", stderr)
            template.unlink()
            self.assertEqual(self.run_cli(arguments)[0:2], (1, ""))

    def test_exact_origin_evidence_and_thresholds(self):
        result = contracts.origin_evidence(metrics(), SINCE, NOW, "regional-apis", HOSTS)
        self.assertEqual(result, {
            "status": "healthy", "reasons": [],
            "origins": [{"origin": host + ":443", "latestBucketUtc": "2026-11-03T18:11:00Z",
                         "minimumPercent": 100} for host in HOSTS],
        })
        for minimum in (None, 0, 99.99):
            fixture = metrics()
            fixture["value"][0]["timeseries"][0]["data"][-1]["minimum"] = minimum
            result = contracts.origin_evidence(fixture, SINCE, NOW, "regional-apis", HOSTS)
            self.assertEqual(result["status"], "waiting")
            self.assertEqual(len(result["origins"]), 1)
            self.assertEqual(len(result["reasons"]), 1)
        for minimum in ("100", True, -1, 101, float("nan"), float("inf")):
            fixture = metrics()
            fixture["value"][0]["timeseries"][0]["data"][-1]["minimum"] = minimum
            with self.subTest(minimum=minimum), self.assertRaises(contracts.ContractError):
                contracts.origin_evidence(fixture, SINCE, NOW, "regional-apis", HOSTS)
        self.assertEqual(contracts.origin_evidence(metrics(), SINCE, "2026-11-03T18:16:00Z", "regional-apis", HOSTS)["status"], "healthy")
        self.assertEqual(contracts.origin_evidence(metrics(), SINCE, "2026-11-03T18:16:00.001Z", "regional-apis", HOSTS)["status"], "waiting")
        self.assertEqual(contracts.origin_evidence(metrics(), "2026-11-03T18:10:00.001Z", NOW, "regional-apis", HOSTS)["status"], "waiting")

    def test_cli_errors_are_explicit_without_payload_leakage(self):
        for payload in ('{ "UNRELATED_SECRET": "do-not-echo",', '[]'):
            code, stdout, stderr = self.run_cli(["ingress"], payload)
            self.assertEqual((code, stdout), (1, ""))
            self.assertIn("ERROR:", stderr)
            self.assertNotIn("do-not-echo", stderr)
        arguments = ["origins", "--since", SINCE, "--now", NOW, "--group", "regional-apis", "--hosts", *HOSTS]
        code, stdout, stderr = self.run_cli(arguments, json.dumps(metrics()))
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(stdout)["status"], "healthy")
        self.assertEqual(stderr, "")
        self.assertEqual(self.run_cli(arguments, "{}")[0:2], (1, ""))
        self.assertEqual(self.run_cli(arguments + ["--since", "not-a-timestamp"], json.dumps(metrics()))[0:2], (1, ""))


if __name__ == "__main__":
    unittest.main()
