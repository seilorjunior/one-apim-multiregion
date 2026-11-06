"""Offline bootstrap purchases/consent are simulated; no Azure requests are made."""
import contextlib
import copy
import datetime as dt
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("domain_bootstrap", ROOT / "scripts" / "domain_bootstrap.py")
bootstrap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bootstrap)
SCOPE = "/subscriptions/test-sub/resourceGroups/rg-domain"
DOMAIN = "owned-domain.org"
VAULT = SCOPE + "/providers/Microsoft.KeyVault/vaults/kv-test"
ORDER = SCOPE + "/providers/Microsoft.CertificateRegistration/certificateOrders/wildcard"
ZONE = SCOPE + "/providers/Microsoft.Network/dnsZones/" + DOMAIN
BINDING = ORDER + "/certificates/gateway"
DOMAIN_ID = SCOPE + "/providers/Microsoft.DomainRegistration/domains/" + DOMAIN


class FakeAzure:
    def __init__(self, exists=True, issued=True):
        self.data = {}
        self.calls = []
        self.auto_issue = True
        self.conflicts = 0
        if exists:
            self.seed(issued)

    def seed(self, issued):
        now = dt.datetime.now(dt.timezone.utc)
        self.data[SCOPE] = {"id": SCOPE}
        self.data[VAULT] = {
            "id": VAULT, "name": "kv-test", "type": "Microsoft.KeyVault/vaults",
            "properties": {"enableRbacAuthorization": True, "publicNetworkAccess": "Disabled"},
        }
        self.data[DOMAIN_ID] = {
            "id": DOMAIN_ID, "name": DOMAIN, "type": "Microsoft.DomainRegistration/domains",
            "properties": {"registrationStatus": "Active", "dnsZoneId": ZONE},
        }
        self.data[ZONE] = {"id": ZONE, "name": DOMAIN, "type": "Microsoft.Network/dnsZones"}
        self.data[ORDER] = {
            "id": ORDER, "type": "Microsoft.CertificateRegistration/certificateOrders",
            "properties": {
                "distinguishedName": "CN=*." + DOMAIN, "status": "Issued" if issued else "Pendingissuance",
                "provisioningState": "Succeeded", "productType": "StandardDomainValidatedWildCardSsl",
                "isPrivateKeyExternal": False, "domainVerificationToken": "public-dns-validation",
                "signedCertificate": {
                    "subject": "CN=*." + DOMAIN,
                    "notBefore": (now - dt.timedelta(days=1)).isoformat(),
                    "notAfter": (now + dt.timedelta(days=30)).isoformat(),
                },
            },
        }
        self.data[BINDING] = {"properties": {
            "keyVaultId": VAULT, "keyVaultSecretName": "gateway-origin", "provisioningState": "Succeeded",
        }}

    def get(self, identifier, api=None):
        self.calls.append(("GET", identifier))
        return copy.deepcopy(self.data.get(identifier))

    def resources(self, scope, resource_type=None):
        return [copy.deepcopy(r) for r in self.data.values()
                if r.get("type") and r["id"].startswith(scope + "/")
                and (not resource_type or r["type"] == resource_type)]

    def put(self, identifier, body, api=None, headers=None):
        self.calls.append(("PUT", identifier))
        if identifier.endswith("/TXT/@") and self.conflicts:
            self.conflicts -= 1
            self.data[identifier]["properties"]["TXTRecords"].append({"value": ["concurrent-value"]})
            raise bootstrap.ArmError(412, "PreconditionFailed")
        self.data[identifier] = copy.deepcopy(body)
        if identifier == BINDING:
            self.data[identifier]["properties"]["provisioningState"] = "Succeeded"
        return {}

    def post(self, identifier, api=None):
        self.calls.append(("POST", identifier))
        if self.auto_issue:
            self.data[ORDER]["properties"]["status"] = "Issued"

    def deploy(self, group, parameters, existing_vault, existing_domain):
        self.calls.append(("DEPLOY", group))
        self.seed(False)
        self.data.pop(BINDING)

    def register_providers(self, deadline, clock, sleep):
        self.calls.append(("REGISTER", "bootstrap-providers"))


class DomainBootstrapTests(unittest.TestCase):
    def setUp(self):
        self.values = {
            "AZURE_ENV_NAME": "test-private", "AZURE_SUBSCRIPTION_ID": "test-sub",
            "AZURE_LOCATION": "westus3", "AZURE_SECONDARY_LOCATION": "centralus",
            "APP_DOMAIN_BOOTSTRAP_RESOURCE_GROUP": "rg-domain",
        }
        self.parameters = {
            "domainName": {"value": DOMAIN}, "authorizePurchases": {"value": False},
            "registrationContact": {"value": {
                "nameFirst": "DO-NOT-LOG-REGISTRANT", "nameLast": "Test",
                "email": "test@example.org", "phone": "+1.2025550100", "addressMailing": {"city": "Test"},
            }},
            "domainPurchaseConsent": {"value": {
                "agreementKeys": ["SIMULATED"], "agreedAt": "2026-11-04T00:00:00Z", "agreedBy": "192.0.2.1",
            }},
            "certificateIssuerPrincipalId": {"value": "00000000-0000-0000-0000-000000000001"},
        }
        self.saved = {}
        self.seconds = 0
        self.output = io.StringIO()

    def sleep(self, seconds):
        self.seconds += seconds

    def run_bootstrap(self, client, provision=False, wait=60):
        with contextlib.redirect_stdout(self.output):
            return bootstrap.ensure_bootstrap(
                self.values, self.parameters, provision, client,
                self.saved.__setitem__, self.sleep, lambda: self.seconds, wait,
            )

    def test_existing_certificate_is_reused_without_authorization_or_cloud_mutations(self):
        client = FakeAzure()
        outputs = self.run_bootstrap(client, provision=True)
        self.assertEqual(outputs["APP_GATEWAY_CERTIFICATE_ORDER_ID"], ORDER)
        self.assertTrue(all(call[0] == "GET" for call in client.calls))
        self.assertNotIn("DO-NOT-LOG", self.output.getvalue())
        self.values.update(outputs)
        self.saved.clear()
        self.run_bootstrap(client)
        self.assertEqual(self.saved, {})

    def test_preview_never_purchases_even_with_authorization(self):
        self.parameters["authorizePurchases"]["value"] = True
        for exists in (False, True):
            client = FakeAzure(exists)
            if exists:
                client.data.pop(ORDER)
            with self.assertRaisesRegex(bootstrap.BootstrapError, "preview"):
                self.run_bootstrap(client)
            self.assertTrue(all(call[0] == "GET" for call in client.calls))

    def test_missing_resources_need_explicit_purchase_consent(self):
        client = FakeAzure(False)
        with self.assertRaisesRegex(bootstrap.BootstrapError, "Purchases are disabled"):
            self.run_bootstrap(client, provision=True)
        self.assertTrue(all(call[0] == "GET" for call in client.calls))
        self.parameters["authorizePurchases"]["value"] = True
        self.parameters["domainPurchaseConsent"]["value"] = {}
        with self.assertRaisesRegex(bootstrap.BootstrapError, "actual|Actual"):
            self.run_bootstrap(client, provision=True)
        self.assertNotIn("DO-NOT-LOG", self.output.getvalue())

    def test_initial_purchase_waits_for_issuance_and_sync_and_retry_does_not_buy(self):
        client = FakeAzure(False)
        self.parameters["authorizePurchases"]["value"] = True
        outputs = self.run_bootstrap(client, provision=True)
        self.assertEqual(sum(call[0] == "DEPLOY" for call in client.calls), 1)
        self.assertIn(("POST", ORDER + "/verifyDomainOwnership"), client.calls)
        self.assertEqual(client.data[BINDING]["properties"]["provisioningState"], "Succeeded")
        self.assertEqual(outputs["APP_GATEWAY_PRIMARY_HOST"], "gw-westus3." + DOMAIN)
        self.run_bootstrap(client, provision=True)
        self.assertEqual(sum(call[0] == "DEPLOY" for call in client.calls), 1)

    def test_pending_order_resumes_without_purchase_authorization(self):
        client = FakeAzure(issued=False)
        self.run_bootstrap(client, provision=True)
        self.assertFalse(any(call[0] == "DEPLOY" for call in client.calls))

    def test_pending_order_in_preview_never_writes_or_claims_success(self):
        client = FakeAzure(issued=False)
        with self.assertRaisesRegex(bootstrap.BootstrapError, "read-only"):
            self.run_bootstrap(client)
        self.assertTrue(all(call[0] == "GET" for call in client.calls))
        self.assertFalse(self.saved)

    def test_timeout_failed_and_expired_orders_do_not_trigger_replacement(self):
        client = FakeAzure(issued=False)
        client.auto_issue = False
        with self.assertRaisesRegex(bootstrap.BootstrapError, "timed out"):
            self.run_bootstrap(client, provision=True, wait=20)
        self.assertEqual(self.seconds, 20)
        self.assertFalse(self.saved)
        for field, value in (("status", "Expired"), ("status", "Revoked"), ("provisioningState", "Failed")):
            client = FakeAzure()
            client.data[ORDER]["properties"][field] = value
            with self.assertRaisesRegex(bootstrap.BootstrapError, "forbidden"):
                self.run_bootstrap(client, provision=True)
            self.assertFalse(any(call[0] != "GET" for call in client.calls))

    def test_txt_preserves_other_values_ttl_metadata_and_retries_etag_conflict(self):
        client = FakeAzure(issued=False)
        identifier = ZONE + "/TXT/@"
        client.data[identifier] = {"etag": "original", "properties": {
            "TTL": 3600, "metadata": {"owner": "keep"},
            "TXTRecords": [{"value": ["v=spf1 ", "-all"]}],
        }}
        client.conflicts = 1
        self.run_bootstrap(client, provision=True)
        result = client.data[identifier]["properties"]
        self.assertEqual(result["TTL"], 3600)
        self.assertEqual(result["metadata"], {"owner": "keep"})
        self.assertEqual(len(result["TXTRecords"]), 3)
        self.assertEqual(result["TXTRecords"][0], {"value": ["v=spf1 ", "-all"]})
        writes = len([call for call in client.calls if call == ("PUT", identifier)])
        bootstrap.merge_txt(client, ZONE, "public-dns-validation")
        self.assertEqual(len([call for call in client.calls if call == ("PUT", identifier)]), writes)

    def test_conflicting_order_or_binding_is_not_overwritten(self):
        self.values["APP_GATEWAY_CERTIFICATE_ORDER_ID"] = ORDER.replace("rg-domain", "rg-unrelated")
        client = FakeAzure(False)
        self.parameters["authorizePurchases"]["value"] = True
        with self.assertRaisesRegex(bootstrap.BootstrapError, "outside"):
            self.run_bootstrap(client, provision=True)
        self.assertFalse(client.calls)
        self.values.pop("APP_GATEWAY_CERTIFICATE_ORDER_ID")
        client = FakeAzure()
        client.data[BINDING]["properties"]["keyVaultId"] = "/another-vault"
        with self.assertRaisesRegex(bootstrap.BootstrapError, "will not be replaced"):
            self.run_bootstrap(client, provision=True)
        self.assertTrue(all(call[0] == "GET" for call in client.calls))

    def test_http_cli_failures_do_not_leak_registrant_data(self):
        result = type("Result", (), {"returncode": 1, "stdout": "", "stderr": "DO-NOT-LOG-REGISTRANT"})()
        with patch.object(bootstrap.shutil, "which", return_value="az"), patch.object(bootstrap.subprocess, "run", return_value=result):
            with self.assertRaises(bootstrap.BootstrapError) as error:
                bootstrap.command("az", ["deployment", "group", "validate"])
            self.assertNotIn("DO-NOT-LOG", str(error.exception))

    def test_cli_preview_plan_rejects_replacement_before_submit(self):
        azure = bootstrap.Azure.__new__(bootstrap.Azure)
        azure.subscription = "test-sub"
        changes = [{"id": ORDER, "type": "Create"}, {"id": VAULT + "-other", "type": "Create"}, {"id": DOMAIN_ID, "type": "Modify"}]
        with patch.object(bootstrap, "command", side_effect=[None, changes]) as cli:
            with self.assertRaisesRegex(bootstrap.BootstrapError, "replace the existing vault"):
                azure.deploy("rg-domain", self.parameters, VAULT, True)
            self.assertFalse(any("create" in call.args[1] for call in cli.call_args_list))

    def test_running_deployment_is_waited_without_another_submission(self):
        client = FakeAzure(issued=False)
        client.data[SCOPE + "/providers/Microsoft.Resources/deployments/" + bootstrap.DEPLOYMENT] = {
            "properties": {"provisioningState": "Running"},
        }
        with self.assertRaisesRegex(bootstrap.BootstrapError, "deployment wait timed out"):
            self.run_bootstrap(client, provision=True, wait=10)
        self.assertTrue(all(call[0] == "GET" for call in client.calls))

    def test_matching_order_in_another_group_blocks_duplicate_purchase(self):
        client = FakeAzure(False)
        other = FakeAzure().data[ORDER]
        other["id"] = ORDER.replace("rg-domain", "rg-elsewhere")
        client.data[other["id"]] = other
        self.parameters["authorizePurchases"]["value"] = True
        with self.assertRaisesRegex(bootstrap.BootstrapError, "matching wildcard order already exists"):
            self.run_bootstrap(client, provision=True)
        self.assertFalse(any(call[0] in ("DEPLOY", "REGISTER") for call in client.calls))

    def test_existing_manual_certificate_is_not_replaced_with_a_paid_order(self):
        client = FakeAzure()
        client.data.pop(ORDER)
        self.values["APP_GATEWAY_CERTIFICATE_SECRET_ID"] = "https://kv-test.vault.azure.net/secrets/imported"
        self.parameters["authorizePurchases"]["value"] = True
        with self.assertRaisesRegex(bootstrap.BootstrapError, "preserve the manual workflow"):
            self.run_bootstrap(client, provision=True)
        self.assertTrue(all(call[0] == "GET" for call in client.calls))

    def test_conflicting_domain_settings_fail_before_any_cloud_operation(self):
        self.values["APP_GATEWAY_DNS_SUFFIX"] = "another-domain.org"
        client = FakeAzure(False)
        self.parameters["authorizePurchases"]["value"] = True
        with self.assertRaisesRegex(bootstrap.BootstrapError, "DNS suffix differs"):
            self.run_bootstrap(client, provision=True)
        self.assertFalse(client.calls)

    def test_order_appearing_during_preview_is_not_submitted_again(self):
        azure = bootstrap.Azure.__new__(bootstrap.Azure)
        azure.subscription = "test-sub"
        changes = [{"id": ORDER, "type": "Create"}, {"id": VAULT, "type": "Create"}, {"id": DOMAIN_ID, "type": "Create"}]
        with patch.object(bootstrap, "command", side_effect=[None, changes]) as cli, patch.object(azure, "get", return_value={"id": ORDER}):
            with contextlib.redirect_stdout(self.output):
                azure.deploy("rg-domain", self.parameters, None, False)
            self.assertFalse(any("create" in call.args[1] for call in cli.call_args_list))

    def test_hook_purchase_stage_is_separate_from_preview_preparation(self):
        yaml = (ROOT / "azure.yaml").read_text()
        preup, preprovision = yaml.split("  preprovision:", 1)
        self.assertIn("Sync-DomainBootstrap.ps1 -Provision", preup)
        self.assertIn("Sync-DomainBootstrap.sh --provision", preup)
        self.assertNotIn("Sync-DomainBootstrap", preprovision)
        for shell, extension in (("powershell", "ps1"), ("bash", "sh")):
            prepare = (ROOT / "scripts" / shell / f"Prepare-Lab.{extension}").read_text()
            line = next(line for line in prepare.splitlines() if f"Sync-DomainBootstrap.{extension}" in line)
            self.assertNotIn("-Provision", line)
            self.assertNotIn("--provision", line)


if __name__ == "__main__":
    unittest.main()
