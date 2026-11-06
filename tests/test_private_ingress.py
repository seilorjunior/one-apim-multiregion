"""Offline ingress configuration, certificate rejection, and scoped approval parity."""
import base64
import copy
import datetime as dt
import json
import os
from pathlib import Path
import re
import ssl
import subprocess
import sys
import tempfile
import unittest
import uuid

from test_reliability import BASH, PWSH, ROOT


def mock_command(tool, args):
    path = Path(os.environ["PRIVATE_FIXTURE"])
    data = json.loads(path.read_text())
    data["calls"].append([tool, *args])
    path.write_text(json.dumps(data))
    if tool == "azd":
        if args == ["env", "get-values"]:
            print("\n".join(f'{key}="{value}"' for key, value in data["env"].items()))
            return
        raise AssertionError(args)
    if args[:2] == ["keyvault", "show"]:
        print(json.dumps(data["vault"]))
    elif args[:3] == ["keyvault", "certificate", "show"]:
        print(json.dumps(data["certificate"]))
    elif args[:1] == ["rest"]:
        url = args[args.index("--url") + 1]
        if "/Microsoft.CertificateRegistration/certificateOrders/" in url:
            print(json.dumps(data["order"]))
        elif url.split("?", 1)[0].lower() in data.get("network", {}):
            print(json.dumps(data["network"][url.split("?", 1)[0].lower()]))
        elif "network" in data and "/providers/microsoft.network/" in url.lower():
            raise AssertionError(f"Unexpected network resource URL: {url!r}")
        elif "--query" in args:
            gateway = url.split("?", 1)[0]
            region = next(key for key in ("PRIMARY", "SECONDARY") if data["env"][f"APP_GATEWAY_{key}_ID"] == gateway)
            print(json.dumps(data["connections"][region]))
        else:
            region = "PRIMARY" if "/origins/br?" in url else "SECONDARY"
            origin = copy.deepcopy(data["origins"][region])
            if region in data["approved"]:
                origin["properties"]["sharedPrivateLinkResource"]["status"] = "Approved"
            print(json.dumps(origin))
    elif args[:3] == ["network", "private-endpoint-connection", "approve"]:
        identifier = args[args.index("--id") + 1]
        region = next(key for key in ("PRIMARY", "SECONDARY") if identifier.startswith(data["env"][f"APP_GATEWAY_{key}_ID"] + "/"))
        data["approved"].append(region)
        path.write_text(json.dumps(data))
        print("{}")
    else:
        raise AssertionError(args)


if __name__ == "__main__" and len(sys.argv) > 1 and sys.argv[1] == "--mock":
    mock_command(sys.argv[2], sys.argv[3:])
    sys.exit(0)


@unittest.skipUnless(BASH and PWSH, "Both shells are required")
class PrivateIngressTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="lab-private-ingress-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        subscription = "test-sub"
        group = "rg-test"
        profile_name = "afd-" + "long-environment-name-" * 4
        scope = f"/subscriptions/{subscription}/resourceGroups/{group}"
        profile = scope + "/providers/Microsoft.Cdn/profiles/" + profile_name
        self.fixture = {
            "calls": [], "approved": [],
            "env": {
                "APP_INGRESS_MODE": "private", "AZURE_SUBSCRIPTION_ID": subscription,
                "AZURE_RESOURCE_GROUP": group, "AZURE_FRONT_DOOR_PROFILE": profile_name,
                "AZURE_LOCATION": "westus3", "AZURE_SECONDARY_LOCATION": "centralus",
                "APP_GATEWAY_DNS_SUFFIX": "owned-domain.org",
                "APP_GATEWAY_KEY_VAULT_NAME": "test-vault",
                "APP_GATEWAY_KEY_VAULT_RESOURCE_GROUP": "rg-certs",
                "APP_GATEWAY_CERTIFICATE_SECRET_ID": "https://test-vault.vault.azure.net/secrets/gateway",
            },
            "origins": {}, "connections": {},
            "vault": {
                "rbac": True, "publicNetwork": "Enabled", "defaultAction": "Allow", "bypass": "AzureServices",
                "properties": {"enableRbacAuthorization": True, "publicNetworkAccess": "Enabled", "networkAcls": {"defaultAction": "Allow"}},
            },
            "certificate": {
                "enabled": True, "exportable": True, "contentType": "application/x-pkcs12",
                "sid": "https://test-vault.vault.azure.net/secrets/gateway/version",
            },
        }
        for region, location in (("PRIMARY", "westus3"), ("SECONDARY", "centralus")):
            gateway = f"{scope}/providers/Microsoft.Network/applicationGateways/agw-{region.lower()}"
            host = f"gw-{location}.owned-domain.org"
            self.fixture["env"][f"APP_GATEWAY_{region}_ID"] = gateway
            self.fixture["env"][f"APP_GATEWAY_{region}_HOST"] = host
            self.fixture["origins"][region] = {"properties": {
                "hostName": host, "originHostHeader": host, "enforceCertificateNameCheck": True,
                "provisioningState": "Succeeded", "enabledState": "Enabled",
                "sharedPrivateLinkResource": {
                    "privateLink": {"id": gateway}, "groupId": "private", "status": "Pending",
                    "privateLinkLocation": location, "requestMessage": self.marker(profile),
                },
            }}
            self.fixture["connections"][region] = [{
                "id": gateway + "/privateEndpointConnections/expected",
                "properties": {"provisioningState": "Succeeded", "privateLinkServiceConnectionState": {"status": "Pending", "description": self.marker(profile)}},
            }]

    def run_shells(self, action, success=True):
        results = []
        for shell in ("powershell", "bash"):
            with self.subTest(shell=shell, action=action):
                path = self.directory / f"{shell}.json"
                path.write_text(json.dumps(self.fixture))
                env = os.environ.copy()
                env.update({
                    "PRIVATE_FIXTURE": str(path), "PRIVATE_MOCK": Path(__file__).as_posix(),
                    "PRIVATE_PYTHON": Path(sys.executable).as_posix(),
                })
                if shell == "powershell":
                    script = self.directory / "run.ps1"
                    script.write_text(r'''
param($Common, $Action, $Connect, $Tls)
. $Common
function az { & $env:PRIVATE_PYTHON $env:PRIVATE_MOCK --mock az @args }
function azd { & $env:PRIVATE_PYTHON $env:PRIVATE_MOCK --mock azd @args }
function Start-Sleep { param($Seconds) }
$values = Get-LabEnvironment
switch ($Action) {
    'config' { Set-LabIngressConfiguration $values; $values | ConvertTo-Json -Compress }
    'origins' { @(Get-LabPrivateOrigins $values) | ConvertTo-Json -Compress }
    'certificate' { Assert-LabGatewayCertificate $values $Tls }
    'vault-network' { Assert-LabGatewayVaultNetwork $values }
    'check' { & $Connect }
    'approve' { & $Connect -Approve -Confirm:$false -WaitSeconds 60 }
    'approve-now' { & $Connect -Approve -Confirm:$false -WaitSeconds 0 }
}
''', encoding="utf-8")
                    command = [
                        PWSH, "-NoProfile", "-File", str(script),
                        str(ROOT / "scripts" / shell / "Lab.Common.ps1"), action,
                        str(ROOT / "scripts" / shell / "Connect-PrivateOrigins.ps1"), str(self.directory / "tls"),
                    ]
                else:
                    command = [BASH, "-c", r'''
az() { MSYS2_ARG_CONV_EXCL='*' "$PRIVATE_PYTHON" "$PRIVATE_MOCK" --mock az "$@"; }
azd() { MSYS2_ARG_CONV_EXCL='*' "$PRIVATE_PYTHON" "$PRIVATE_MOCK" --mock azd "$@"; }
sleep() { :; }
export -f az azd sleep
source "$1/Lab.Common.sh"
lab_load_environment
case "$2" in
    config)
        lab_ingress_configuration
        values=()
        for key in "${!LAB_ENV[@]}"; do values+=("$key" "${LAB_ENV[$key]}"); done
        "$LAB_PYTHON" -c 'import json,sys; print(json.dumps(dict(zip(sys.argv[1::2], sys.argv[2::2]))))' "${values[@]}"
        ;;
    origins) lab_private_origins ;;
    certificate) lab_gateway_certificate "$3" ;;
    vault-network) lab_gateway_vault_network ;;
    check) bash "$1/Connect-PrivateOrigins.sh" ;;
    approve) bash "$1/Connect-PrivateOrigins.sh" --approve --yes --wait-seconds 60 ;;
    approve-now) bash "$1/Connect-PrivateOrigins.sh" --approve --yes --wait-seconds 0 ;;
esac
''', "--", (ROOT / "scripts" / shell).as_posix(), action, (self.directory / "tls").as_posix()]
                result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=60, cwd=ROOT)
                self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
                self.assertNotIn("command not found", result.stderr)
                self.assertNotIn("IndentationError", result.stderr)
                self.assertNotIn("NameError", result.stderr)
                self.assertNotIn("AssertionError", result.stderr)
                self.assertNotIn("KeyError", result.stderr)
                state = json.loads(path.read_text())
                results.append((result.stdout + result.stderr, state["calls"]))
        return results

    def test_public_default_and_generated_private_hostnames(self):
        for key in ("APP_GATEWAY_PRIMARY_HOST", "APP_GATEWAY_SECONDARY_HOST"):
            self.fixture["env"].pop(key)
        for output, _ in self.run_shells("config"):
            values = json.loads(output)
            self.assertEqual(values["APP_GATEWAY_PRIMARY_HOST"], "gw-westus3.owned-domain.org")
            self.assertEqual(values["APP_GATEWAY_SECONDARY_HOST"], "gw-centralus.owned-domain.org")
        self.fixture["env"] = {}
        for output, calls in self.run_shells("config"):
            self.assertEqual(json.loads(output)["APP_INGRESS_MODE"], "public")
            self.assertEqual(len(calls), 1)

    def test_invalid_configuration_fails_before_azure_reads(self):
        original = copy.deepcopy(self.fixture["env"])
        cases = [
            {"APP_INGRESS_MODE": "invalid"}, {"APP_INGRESS_MODE": ""},
            {"APP_GATEWAY_PRIMARY_HOST": "gw.example.com"},
            {"APP_GATEWAY_PRIMARY_HOST": "10.10.3.10"},
            {"APP_GATEWAY_PRIMARY_HOST": "tenant.azure-api.net"},
            {"APP_GATEWAY_PRIMARY_HOST": original["APP_GATEWAY_SECONDARY_HOST"]},
            {"APP_GATEWAY_CERTIFICATE_SECRET_ID": original["APP_GATEWAY_CERTIFICATE_SECRET_ID"] + "/version"},
            {"APP_GATEWAY_KEY_VAULT_NAME": "another-vault"},
            {"APP_GATEWAY_KEY_VAULT_RESOURCE_GROUP": ""},
        ]
        for changes in cases:
            with self.subTest(changes=changes):
                self.fixture["env"] = original | changes
                for _, calls in self.run_shells("config", success=False):
                    self.assertTrue(all(call[0] == "azd" for call in calls))

    def test_default_check_never_approves_and_explicit_approval_is_scoped(self):
        for _, calls in self.run_shells("check", success=False):
            self.assertFalse(any("approve" in call for call in calls))
        for output, calls in self.run_shells("approve"):
            self.assertIn("PASS:", output)
            approvals = [call for call in calls if "approve" in call]
            self.assertEqual(len(approvals), 2)
            for call in approvals:
                self.assertTrue(call[call.index("--id") + 1].endswith("/privateEndpointConnections/expected"))
                description = call[call.index("--description") + 1]
                self.assertEqual(description, self.marker(self.profile_id()))
                self.assertEqual(len(description), 45)
                self.assertLessEqual(len(description), 140)

    @staticmethod
    def marker(profile):
        return "apim-lab:" + str(uuid.uuid5(uuid.UUID("11fb06fb-712d-4ddd-98c7-e71bbd588830"), profile.lower()))

    def profile_id(self):
        env = self.fixture["env"]
        return f'/subscriptions/{env["AZURE_SUBSCRIPTION_ID"]}/resourceGroups/{env["AZURE_RESOURCE_GROUP"]}/providers/Microsoft.Cdn/profiles/{env["AZURE_FRONT_DOOR_PROFILE"]}'

    def test_legacy_marker_is_recognized_but_approval_uses_compact_marker(self):
        self.assertGreater(len("apim-lab:" + self.profile_id()), 140)
        self.setUp_fixture_connections()
        for _, calls in self.run_shells("approve"):
            approvals = [call for call in calls if "approve" in call]
            self.assertEqual(len(approvals), 2)
            for call in approvals:
                self.assertEqual(call[call.index("--description") + 1], self.marker(self.profile_id()))

    def test_unreported_origin_status_is_initializing_not_approved(self):
        for status in (None, "", "missing"):
            for origin in self.fixture["origins"].values():
                link = origin["properties"]["sharedPrivateLinkResource"]
                if status == "missing":
                    link.pop("status", None)
                else:
                    link["status"] = status
            for output, calls in self.run_shells("origins"):
                self.assertIn("Initializing", output)
                self.assertNotIn("PASS:", output)
                self.assertFalse(any("approve" in call for call in calls))

    def test_initializing_origins_allow_only_explicit_scoped_approval(self):
        for origin in self.fixture["origins"].values():
            origin["properties"]["sharedPrivateLinkResource"]["status"] = None
        for output, calls in self.run_shells("check", success=False):
            self.assertIn("pending or initializing", output)
            self.assertFalse(any("approve" in call for call in calls))
        for output, calls in self.run_shells("approve"):
            self.assertIn("PASS:", output)
            self.assertEqual(len([c for c in calls if "approve" in c]), 2)

    def test_unreported_status_accepts_verified_gateway_approval_without_mutation(self):
        for origin in self.fixture["origins"].values():
            origin["properties"]["sharedPrivateLinkResource"]["status"] = None
        for connections in self.fixture["connections"].values():
            connections[0]["properties"]["privateLinkServiceConnectionState"]["status"] = "Approved"
        for output, calls in self.run_shells("check"):
            self.assertIn("PASS:", output)
            self.assertIn("gateway-side", output)
            self.assertIn("Runtime TLS/API health", output)
            self.assertFalse(any("approve" in call for call in calls))
        for output, _ in self.run_shells("origins"):
            self.assertIn("ApprovedAtGateway", output)

    def test_gateway_approval_requires_complete_matching_origin_evidence(self):
        for origin in self.fixture["origins"].values():
            origin["properties"]["sharedPrivateLinkResource"]["status"] = None
        for connections in self.fixture["connections"].values():
            connections[0]["properties"]["privateLinkServiceConnectionState"]["status"] = "Approved"
        original = copy.deepcopy(self.fixture)
        cases = (
            ("origin", "provisioningState", "Failed"),
            ("origin", "enabledState", "Disabled"),
            ("origin", "originHostHeader", "another.example.org"),
            ("link", "privateLinkLocation", "eastus"),
            ("link", "requestMessage", "unrelated request"),
            ("connection", "provisioningState", "Updating"),
        )
        for target, key, value in cases:
            with self.subTest(target=target, key=key):
                self.fixture = copy.deepcopy(original)
                if target == "origin":
                    properties = self.fixture["origins"]["PRIMARY"]["properties"]
                elif target == "link":
                    properties = self.fixture["origins"]["PRIMARY"]["properties"]["sharedPrivateLinkResource"]
                else:
                    properties = self.fixture["connections"]["PRIMARY"][0]["properties"]
                properties[key] = value
                for _, calls in self.run_shells("check", success=False):
                    self.assertFalse(any("approve" in call for call in calls))

    def test_explicit_front_door_status_is_never_overridden_by_gateway_approval(self):
        for connections in self.fixture["connections"].values():
            connections[0]["properties"]["privateLinkServiceConnectionState"]["status"] = "Approved"
        for status in ("Pending", "Rejected", "Disconnected"):
            for origin in self.fixture["origins"].values():
                origin["properties"]["sharedPrivateLinkResource"]["status"] = status
            for output, calls in self.run_shells("check", success=False):
                self.assertNotIn("PASS:", output)
                self.assertFalse(any("approve" in call for call in calls))

    def test_initializing_without_matching_request_waits_without_approval(self):
        for origin in self.fixture["origins"].values():
            origin["properties"]["sharedPrivateLinkResource"]["status"] = None
        for connections in ([], self.fixture["connections"]["PRIMARY"]):
            self.fixture["connections"] = {"PRIMARY": connections, "SECONDARY": []}
            if connections:
                connections[0]["properties"]["privateLinkServiceConnectionState"]["description"] = "unrelated request"
            for output, calls in self.run_shells("approve-now", success=False):
                plain_output = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", output)
                plain_output = re.sub(r"\s*\|\s*", " ", plain_output)
                self.assertIn("both origin approvals are not yet verified", " ".join(plain_output.split()))
                self.assertFalse(any("approve" in call for call in calls))

    def test_initializing_origin_rejects_terminal_gateway_request(self):
        self.fixture["origins"]["PRIMARY"]["properties"]["sharedPrivateLinkResource"]["status"] = None
        self.fixture["connections"]["PRIMARY"][0]["properties"]["privateLinkServiceConnectionState"]["status"] = "Rejected"
        for output, calls in self.run_shells("approve-now", success=False):
            self.assertIn("Rejected", output)
            self.assertFalse(any("approve" in call for call in calls))

    def test_unrelated_or_ambiguous_connections_are_not_approved(self):
        for region in ("PRIMARY", "SECONDARY"):
            self.fixture["connections"][region][0]["properties"]["privateLinkServiceConnectionState"]["description"] = "unrelated request"
        for _, calls in self.run_shells("approve-now", success=False):
            self.assertFalse(any("approve" in call for call in calls))
        self.setUp_fixture_connections()
        self.fixture["connections"]["PRIMARY"].append(copy.deepcopy(self.fixture["connections"]["PRIMARY"][0]))
        for _, calls in self.run_shells("approve-now", success=False):
            self.assertFalse(any("approve" in call for call in calls))

    def setUp_fixture_connections(self):
        profile = self.profile_id()
        for region in ("PRIMARY", "SECONDARY"):
            self.fixture["connections"][region][0]["properties"]["privateLinkServiceConnectionState"]["description"] = "apim-lab:" + profile

    def test_origin_drift_rejection_and_connection_scope_are_errors(self):
        original = copy.deepcopy(self.fixture)
        for field, value in (("groupId", "public"), ("status", "Rejected"), ("privateLink", {"id": "/unrelated"})):
            self.fixture = copy.deepcopy(original)
            self.fixture["origins"]["PRIMARY"]["properties"]["sharedPrivateLinkResource"][field] = value
            self.run_shells("origins", success=False)
        self.fixture = copy.deepcopy(original)
        self.fixture["origins"]["PRIMARY"]["properties"]["enforceCertificateNameCheck"] = False
        self.run_shells("origins", success=False)
        self.fixture = copy.deepcopy(original)
        self.fixture["connections"]["PRIMARY"][0]["id"] = "/subscriptions/unrelated/privateEndpointConnections/fake"
        self.run_shells("origins", success=False)

    def test_public_check_is_noop_and_approved_origins_need_no_mutation(self):
        original = copy.deepcopy(self.fixture)
        self.fixture["env"] = {}
        for output, calls in self.run_shells("check"):
            self.assertIn("Public ingress", output)
            self.assertTrue(all(call[0] == "azd" for call in calls))
        self.fixture = original
        for origin in self.fixture["origins"].values():
            origin["properties"]["sharedPrivateLinkResource"]["status"] = "Approved"
        for output, calls in self.run_shells("check"):
            self.assertIn("PASS:", output)
            self.assertFalse(any("approve" in call or "list" in call for call in calls))

    def test_rollback_preserves_in_use_gateway_subnets(self):
        self.fixture["env"]["APP_INGRESS_MODE"] = "public"
        self.run_shells("config", success=False)
        self.fixture["env"]["APP_GATEWAY_NETWORK_MODE"] = "retain"
        for output, _ in self.run_shells("config"):
            self.assertEqual(json.loads(output)["APP_GATEWAY_NETWORK_MODE"], "retain")

    def test_certificate_gate_rejects_lab_ca_and_invalid_metadata(self):
        tls = self.directory / "tls"
        generator = self.directory / "tls.ps1"
        generator.write_text("param($Common,$Tls)\n. $Common\nNew-LabTlsFiles $Tls\n", encoding="utf-8")
        command = [PWSH, "-NoProfile", "-File", str(generator), str(ROOT / "scripts" / "powershell" / "Lab.Common.ps1"), str(tls)]
        subprocess.run(command, check=True, capture_output=True, timeout=30)
        self.fixture["certificate"]["cer"] = base64.b64encode((tls / "root.cer").read_bytes()).decode()
        self.run_shells("certificate", success=False)
        original = copy.deepcopy(self.fixture["certificate"])
        for changes in ({"enabled": False}, {"exportable": False}, {"contentType": "application/x-pem-file"}, {"sid": "https://other.vault.azure.net/secrets/other/version"}):
            self.fixture["certificate"] = original | changes
            self.run_shells("certificate", success=False)
        pem = re.search(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", (tls / "tls.crt").read_text(), re.DOTALL)[0]
        leaf = ssl.PEM_cert_to_DER_cert(pem)
        self.fixture["certificate"] = original | {"cer": base64.b64encode(leaf).decode()}
        self.run_shells("certificate", success=False)

    def test_san_matching_untrusted_chain_cannot_enable_private_ingress(self):
        generator = self.directory / "untrusted.ps1"
        generator.write_text(r'''
param($Common, $Directory)
. $Common
New-LabTlsFiles (Join-Path $Directory 'tls')
$caKey = [Security.Cryptography.RSA]::Create(2048)
$leafKey = [Security.Cryptography.RSA]::Create(2048)
$hash = [Security.Cryptography.HashAlgorithmName]::SHA256
$padding = [Security.Cryptography.RSASignaturePadding]::Pkcs1
$caRequest = [Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=Untrusted test issuer', $caKey, $hash, $padding)
$caRequest.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true, $false, 0, $true))
$ca = $caRequest.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-2), [DateTimeOffset]::UtcNow.AddDays(10))
$request = [Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=Gateway test', $leafKey, $hash, $padding)
$san = [Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
$san.AddDnsName('gw-westus3.owned-domain.org')
$san.AddDnsName('gw-centralus.owned-domain.org')
$request.CertificateExtensions.Add($san.Build())
$leaf = $request.Create($ca, [DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(5), [byte[]]@(1,2,3,4))
try {
    [IO.File]::WriteAllBytes((Join-Path $Directory 'leaf.cer'), $leaf.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert))
    [IO.File]::WriteAllText((Join-Path $Directory 'chain.pem'), $ca.ExportCertificatePem())
}
finally { $leaf.Dispose(); $ca.Dispose(); $leafKey.Dispose(); $caKey.Dispose() }
''', encoding="utf-8")
        subprocess.run(
            [PWSH, "-NoProfile", "-File", str(generator), str(ROOT / "scripts" / "powershell" / "Lab.Common.ps1"), str(self.directory)],
            check=True, capture_output=True, timeout=30,
        )
        self.fixture["certificate"]["cer"] = base64.b64encode((self.directory / "leaf.cer").read_bytes()).decode()
        self.fixture["env"]["APP_GATEWAY_CERTIFICATE_CHAIN_FILE"] = str(self.directory / "chain.pem")
        for output, calls in self.run_shells("certificate", success=False):
            self.assertIn("not trusted", output.lower())
            self.assertFalse(any("secret" in call[1:3] for call in calls))

    def purchased_fixture(self):
        self.fixture["env"]["APP_GATEWAY_CERTIFICATE_ORDER_ID"] = "/subscriptions/test-sub/resourceGroups/rg-certs/providers/Microsoft.CertificateRegistration/certificateOrders/wildcard"
        now = dt.datetime.now(dt.timezone.utc)
        self.fixture["order"] = {
            "status": "Issued", "state": "Succeeded",
            "product": "StandardDomainValidatedWildCardSsl", "externalKey": False,
            "signed": {
                "subject": "CN=*.owned-domain.org",
                "notBefore": (now - dt.timedelta(days=1)).isoformat(),
                "notAfter": (now + dt.timedelta(days=30)).isoformat(),
            },
            "certificates": {"gateway": {
                "keyVaultId": "/subscriptions/test-sub/resourceGroups/rg-certs/providers/Microsoft.KeyVault/vaults/test-vault",
                "keyVaultSecretName": "gateway", "provisioningState": "Succeeded",
            }},
        }

    def test_purchased_certificate_uses_issued_order_without_reading_private_key(self):
        self.purchased_fixture()
        for output, calls in self.run_shells("certificate"):
            self.assertIn("verified", output)
            self.assertFalse(any(call[1:3] == ["keyvault", "certificate"] or call[1:3] == ["keyvault", "secret"] for call in calls))
            self.assertTrue(any("rest" in call for call in calls))

    def test_purchased_certificate_rejects_pending_drift_and_invalid_lifetime(self):
        self.purchased_fixture()
        original = copy.deepcopy(self.fixture)
        for field, value in (("status", "Pendingissuance"), ("state", "Failed"), ("product", "StandardDomainValidatedSsl"), ("externalKey", True)):
            self.fixture = copy.deepcopy(original)
            self.fixture["order"][field] = value
            self.run_shells("certificate", success=False)
        self.fixture = copy.deepcopy(original)
        self.fixture["order"]["certificates"]["gateway"]["keyVaultSecretName"] = "different"
        self.run_shells("certificate", success=False)
        self.fixture = copy.deepcopy(original)
        self.fixture["order"]["signed"]["subject"] = "CN=*.other-domain.org"
        self.run_shells("certificate", success=False)
        self.fixture = copy.deepcopy(original)
        self.fixture["order"]["signed"]["notAfter"] = dt.datetime.now(dt.timezone.utc).isoformat()
        self.run_shells("certificate", success=False)
        self.fixture = copy.deepcopy(original)
        self.fixture["env"]["APP_GATEWAY_CERTIFICATE_ORDER_ID"] = "/subscriptions/another-sub/resourceGroups/rg/providers/Microsoft.CertificateRegistration/certificateOrders/other"
        self.run_shells("certificate", success=False)

    def private_vault_fixture(self):
        self.purchased_fixture()
        self.fixture["env"].update({
            "AZURE_ENV_NAME": "test-private",
            "APP_GATEWAY_KEY_VAULT_NETWORK_MODE": "private-endpoints",
        })
        self.fixture["vault"]["publicNetwork"] = "Disabled"
        self.fixture["vault"]["properties"]["publicNetworkAccess"] = "Disabled"
        vault = self.fixture["order"]["certificates"]["gateway"]["keyVaultId"]
        network = self.fixture["network"] = {}
        scope = "/subscriptions/test-sub/resourceGroups/rg-test/providers/Microsoft.Network"
        for region, prefix in (("PRIMARY", "10.10"), ("SECONDARY", "10.20")):
            gateway = self.fixture["env"][f"APP_GATEWAY_{region}_ID"]
            endpoint = f"{scope}/privateEndpoints/vault-{region.lower()}"
            vnet = f"{scope}/virtualNetworks/vnet-{region.lower()}"
            nic = f"{scope}/networkInterfaces/vault-{region.lower()}"
            zone = f"/subscriptions/test-sub/resourceGroups/rg-dns-{region.lower()}/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net"
            self.fixture["env"][f"APP_GATEWAY_{region}_VAULT_ENDPOINT_ID"] = endpoint
            self.fixture["env"][f"APP_GATEWAY_{region}_VAULT_DNS_ZONE_ID"] = zone
            network[gateway.lower()] = {"properties": {
                "provisioningState": "Succeeded",
                "gatewayIPConfigurations": [{"properties": {"subnet": {"id": vnet + "/subnets/application-gateway"}}}],
            }}
            network[endpoint.lower()] = {"properties": {
                "provisioningState": "Succeeded",
                "subnet": {"id": vnet + "/subnets/vault-private-endpoints"},
                "networkInterfaces": [{"id": nic}],
                "privateLinkServiceConnections": [{"properties": {
                    "privateLinkServiceId": vault, "groupIds": ["vault"],
                    "privateLinkServiceConnectionState": {"status": "Approved"},
                }}],
            }}
            network[vnet.lower()] = {"properties": {"dhcpOptions": {"dnsServers": []}}}
            network[nic.lower()] = {"properties": {
                "privateEndpoint": {"id": endpoint},
                "ipConfigurations": [{"properties": {
                    "subnet": {"id": vnet + "/subnets/vault-private-endpoints"},
                    "privateIPAddress": prefix + ".5.4",
                }}],
            }}
            network[(endpoint + "/privateDnsZoneGroups").lower()] = {"value": [{"properties": {
                "provisioningState": "Succeeded",
                "privateDnsZoneConfigs": [{"properties": {"privateDnsZoneId": zone}}],
            }}]}
            network[(zone + "/virtualNetworkLinks").lower()] = {"value": [{"properties": {
                "provisioningState": "Succeeded", "registrationEnabled": False, "virtualNetwork": {"id": vnet},
            }}]}
            network[(zone + "/A/test-vault").lower()] = {"properties": {"aRecords": [{"ipv4Address": prefix + ".5.4"}]}}

    def test_private_vault_requires_explicit_mode_and_an_issued_order(self):
        self.private_vault_fixture()
        self.fixture["env"].pop("APP_GATEWAY_KEY_VAULT_NETWORK_MODE")
        self.run_shells("certificate", success=False)
        self.fixture["env"]["APP_GATEWAY_KEY_VAULT_NETWORK_MODE"] = "private-endpoints"
        for output, calls in self.run_shells("certificate"):
            self.assertIn("Certificate metadata alone does not prove vault access", output)
            self.assertIn("deployed-topology verification", output)
            self.assertFalse(any(call[1:3] == ["keyvault", "secret"] for call in calls))
        self.fixture["env"].pop("APP_GATEWAY_CERTIFICATE_ORDER_ID")
        self.run_shells("certificate", success=False)
        self.fixture["env"]["APP_GATEWAY_KEY_VAULT_NETWORK_MODE"] = "ignore-firewall"
        self.run_shells("config", success=False)

    def test_private_vault_live_topology_and_noop_public_path(self):
        self.private_vault_fixture()
        for output, calls in self.run_shells("vault-network"):
            self.assertIn("PASS:", output)
            self.assertTrue(all(call[0] == "azd" or call[1:4] == ["rest", "--method", "get"] for call in calls))
        self.fixture["env"]["APP_INGRESS_MODE"] = "public"
        for _, calls in self.run_shells("vault-network"):
            self.assertTrue(all(call[0] == "azd" for call in calls))

    def test_private_vault_rejects_unapproved_or_misbound_endpoints(self):
        self.private_vault_fixture()
        original = copy.deepcopy(self.fixture)
        endpoint = self.fixture["env"]["APP_GATEWAY_PRIMARY_VAULT_ENDPOINT_ID"].lower()
        for field, value in (("privateLinkServiceId", "/wrong/vault"), ("groupIds", ["wrong"]), ("privateLinkServiceConnectionState", {"status": "Pending"})):
            self.fixture = copy.deepcopy(original)
            self.fixture["network"][endpoint]["properties"]["privateLinkServiceConnections"][0]["properties"][field] = value
            for output, _ in self.run_shells("vault-network", success=False):
                self.assertIn("endpoint must target the exact configured vault", output)
        self.fixture = copy.deepcopy(original)
        self.fixture["network"][endpoint]["properties"]["subnet"]["id"] = "/wrong/vnet/subnets/vault-private-endpoints"
        self.run_shells("vault-network", success=False)
        self.fixture = copy.deepcopy(original)
        self.fixture["network"][endpoint]["properties"]["provisioningState"] = "Failed"
        self.run_shells("vault-network", success=False)

    def test_private_vault_rejects_shared_stale_or_custom_dns(self):
        self.private_vault_fixture()
        original = copy.deepcopy(self.fixture)
        zone = self.fixture["env"]["APP_GATEWAY_PRIMARY_VAULT_DNS_ZONE_ID"].lower()
        self.fixture["env"]["APP_GATEWAY_SECONDARY_VAULT_DNS_ZONE_ID"] = zone
        self.run_shells("vault-network", success=False)
        self.fixture = copy.deepcopy(original)
        record = self.fixture["network"][zone + "/a/test-vault"]["properties"]["aRecords"]
        record.append({"ipv4Address": "10.20.5.4"})
        self.run_shells("vault-network", success=False)
        self.fixture = copy.deepcopy(original)
        self.fixture["network"][zone + "/a/test-vault"]["properties"]["aRecords"][0]["ipv4Address"] = "10.20.5.4"
        self.run_shells("vault-network", success=False)
        self.fixture = copy.deepcopy(original)
        self.fixture["network"][zone + "/virtualnetworklinks"]["value"][0]["properties"]["virtualNetwork"]["id"] = "/other/vnet"
        self.run_shells("vault-network", success=False)
        self.fixture = copy.deepcopy(original)
        vnet = "/subscriptions/test-sub/resourcegroups/rg-test/providers/microsoft.network/virtualnetworks/vnet-primary"
        self.fixture["network"][vnet]["properties"]["dhcpOptions"]["dnsServers"] = ["10.0.0.4"]
        self.run_shells("vault-network", success=False)


if __name__ == "__main__":
    unittest.main()
