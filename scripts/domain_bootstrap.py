"""Optional azd domain bootstrap. Never fetch certificate secrets or private keys."""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request


ROOT = Path(__file__).resolve().parents[1]
CERT_API = "2024-11-01"
DNS_API = "2018-05-01"
SECRET = "gateway-origin"
DEPLOYMENT = "domain-bootstrap-azd"


class BootstrapError(RuntimeError):
    pass


class ArmError(BootstrapError):
    def __init__(self, status, code):
        self.status = status
        super().__init__(f"Azure ARM request failed: HTTP {status}, code {code}.")


def command(program, arguments, as_json=False):
    executable = shutil.which(program)
    if not executable:
        raise BootstrapError(f"Required command not found: {program}.")
    try:
        result = subprocess.run(
            [executable, *arguments], capture_output=True, text=True,
            encoding="utf-8", timeout=300, cwd=ROOT,
        )
    except subprocess.TimeoutExpired:
        raise BootstrapError(f"{program} command timed out; inspect Azure state before retrying.") from None
    if result.returncode:
        # Provider errors can echo secure registrant values; never forward raw CLI output.
        raise BootstrapError(
            f"{program} {' '.join(arguments[:3])} failed (exit {result.returncode}). "
            "Inspect the scoped Azure deployment/activity log; secure command output was withheld."
        )
    return json.loads(result.stdout) if as_json else result.stdout


class Azure:
    def __init__(self, subscription):
        self.subscription = subscription
        self.refresh_token()

    def refresh_token(self):
        self.token = command("az", [
            "account", "get-access-token", "--subscription", self.subscription,
            "--resource", "https://management.azure.com/", "--output", "json",
            "--only-show-errors",
        ], True)["accessToken"]
        self.token_time = time.monotonic()

    def request(self, method, path, body=None, headers=None):
        if time.monotonic() - self.token_time >= 2700:
            self.refresh_token()
        url = path if path.startswith("https://") else "https://management.azure.com" + path
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme != "https" or parsed.netloc != "management.azure.com":
            raise BootstrapError("Refusing to send Azure credentials to an unexpected endpoint.")
        request = urllib.request.Request(
            url, method=method,
            data=json.dumps(body).encode("utf-8") if body is not None else None,
            headers={"Authorization": "Bearer " + self.token, "Content-Type": "application/json", **(headers or {})},
        )
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                raw = response.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as error:
            if method == "GET" and error.code == 404:
                return None
            try:
                details = json.loads(error.read()).get("error") or {}
                code = details.get("code", "RequestFailed")
            except (ValueError, AttributeError):
                code = "RequestFailed"
            if not isinstance(code, str) or not re.fullmatch(r"[a-zA-Z0-9_.-]{1,80}", code):
                code = "RequestFailed"
            raise ArmError(error.code, code) from None
        except urllib.error.URLError:
            raise BootstrapError("Azure ARM connection failed; inspect existing state before retrying.") from None

    def get(self, identifier, api=CERT_API):
        return self.request("GET", f"{identifier}?api-version={api}")

    def put(self, identifier, body, api=CERT_API, headers=None):
        return self.request("PUT", f"{identifier}?api-version={api}", body, headers)

    def post(self, identifier, api=CERT_API):
        return self.request("POST", f"{identifier}?api-version={api}", {})

    def resources(self, scope, resource_type=None):
        url = f"{scope}/resources?api-version=2021-04-01"
        if resource_type:
            url += "&$filter=" + urllib.parse.quote("resourceType eq '" + resource_type + "'")
        result = []
        while url:
            page = self.request("GET", url)
            result.extend(page["value"])
            url = page.get("nextLink")
        return result

    def register_providers(self, deadline, clock, sleep):
        for namespace in ("Microsoft.DomainRegistration", "Microsoft.CertificateRegistration", "Microsoft.Network", "Microsoft.KeyVault"):
            identifier = f"/subscriptions/{self.subscription}/providers/{namespace}"
            provider = self.get(identifier, "2021-04-01")
            if provider and provider.get("registrationState") == "Registered":
                continue
            self.post(identifier + "/register", "2021-04-01")
            while True:
                provider = self.get(identifier, "2021-04-01")
                if provider and provider.get("registrationState") == "Registered":
                    break
                if clock() >= deadline:
                    raise BootstrapError(f"Provider registration timed out: {namespace}. No paid deployment submitted.")
                sleep(min(15, max(0, deadline - clock())))

    def deploy(self, group, parameters, existing_vault, existing_domain):
        with tempfile.TemporaryDirectory(prefix="azd-domain-bootstrap-") as directory:
            path = Path(directory) / "parameters.json"
            path.write_text(json.dumps({"parameters": parameters}), encoding="utf-8")
            path.chmod(0o600)
            base = [
                "--subscription", self.subscription, "--resource-group", group,
                "--name", DEPLOYMENT, "--template-file", str(ROOT / "infra" / "domain-bootstrap.bicep"),
                "--parameters", "@" + str(path), "--only-show-errors",
            ]
            command("az", ["deployment", "group", "validate", *base, "--validation-level", "Provider"])
            changes = command("az", [
                "deployment", "group", "what-if", *base, "--validation-level", "Template",
                "--result-format", "FullResourcePayloads", "--no-pretty-print",
                "--query", "changes[].{id:resourceId,type:changeType}", "--output", "json",
            ], True)
            orders = [c for c in changes if re.search(r"/Microsoft\.CertificateRegistration/certificateOrders/[^/]+$", c["id"], re.I)]
            vaults = [c for c in changes if re.search(r"/Microsoft\.KeyVault/vaults/[^/]+$", c["id"], re.I)]
            if len(orders) != 1 or orders[0]["type"] != "Create" or len(vaults) != 1:
                raise BootstrapError("Purchase preview must identify exactly one new order and one dedicated vault.")
            if existing_vault and vaults[0]["id"].lower() != existing_vault.lower():
                raise BootstrapError("Preview would replace the existing vault; refusing to buy a certificate.")
            if any(c["type"] in ("Delete", "Unsupported", "Deploy") for c in changes):
                raise BootstrapError("Bootstrap preview is incomplete or destructive; no purchase submitted.")
            domains = [c for c in changes if "/microsoft.domainregistration/domains/" in c["id"].lower()]
            if len(domains) != 1 or (existing_domain and domains[0]["type"] == "Create"):
                raise BootstrapError("Domain preview conflicts with existing registration; no purchase submitted.")
            # A direct read closes the resource-list eventual-consistency window before submission.
            if self.get(orders[0]["id"]):
                print("An existing order appeared during preview; reusing it without submitting a purchase.")
                return
            command("az", ["deployment", "group", "create", *base, "--no-wait"])


def properties(resource):
    return resource["properties"] if resource else {}


def configured_parameters(path):
    document = json.loads(path.read_text(encoding="utf-8-sig"))
    if not isinstance(document, dict) or not isinstance(document.get("parameters"), dict):
        raise BootstrapError("Expected an ARM parameters document with a parameters object.")
    parameters = document.get("parameters", {})
    if any(not isinstance(p, dict) or set(p) != {"value"} for p in parameters.values()):
        raise BootstrapError("Bootstrap parameters must contain literal values, not unresolved references.")
    return parameters


def require_purchase_inputs(parameters):
    value = lambda key: parameters.get(key, {}).get("value")
    if value("authorizePurchases") is not True:
        raise BootstrapError("Purchases are disabled. Review prices/terms and explicitly set authorizePurchases=true in the protected parameter file.")
    if value("autoRenewDomain") or value("autoRenewCertificate"):
        raise BootstrapError("This bootstrap does not enable renewals; keep both autoRenew values false.")
    contact, consent = value("registrationContact"), value("domainPurchaseConsent")
    if not isinstance(contact, dict) or any(not contact.get(k) for k in ("nameFirst", "nameLast", "email", "phone", "addressMailing")):
        raise BootstrapError("Real registrant contact fields are required; values will not be logged.")
    if not isinstance(consent, dict) or any(not consent.get(k) for k in ("agreementKeys", "agreedAt", "agreedBy")):
        raise BootstrapError("Actual registrar acceptance, timestamp and IP are required.")
    if not re.fullmatch(r"[a-fA-F0-9-]{36}", value("certificateIssuerPrincipalId") or ""):
        raise BootstrapError("Supply the tenant CertificateRegistration service principal object ID.")


def discover(client, scope, domain):
    resources = client.resources(scope)
    matches = lambda kind: [r for r in resources if r["type"].lower() == kind.lower()]
    vaults = matches("Microsoft.KeyVault/vaults")
    orders = matches("Microsoft.CertificateRegistration/certificateOrders")
    domains = matches("Microsoft.DomainRegistration/domains")
    zones = matches("Microsoft.Network/dnsZones")
    if len(vaults) > 1 or len(orders) > 1 or any(r["name"].lower() != domain for r in domains + zones):
        raise BootstrapError("Use a dedicated bootstrap group with one domain, vault and order; ambiguous resources will not be selected.")
    vault = client.get(vaults[0]["id"], "2023-07-01") if vaults else None
    order = client.get(orders[0]["id"]) if orders else None
    if order and properties(order).get("distinguishedName", "").lower() != "cn=*." + domain:
        raise BootstrapError("Existing certificate order belongs to a different domain; refusing another purchase.")
    return vault, order


def wait_deployment(client, scope, deadline, clock, sleep):
    identifier = scope + "/providers/Microsoft.Resources/deployments/" + DEPLOYMENT
    while True:
        deployment = client.get(identifier, "2022-09-01")
        if not deployment:
            return
        state = properties(deployment).get("provisioningState")
        if state == "Succeeded":
            return
        if state in ("Failed", "Canceled"):
            print(f"WARNING: Bootstrap deployment is {state}; inspect existing resources. Only an existing order may be resumed without a new authorization.")
            return
        if clock() >= deadline:
            raise BootstrapError("Bootstrap deployment wait timed out. Resume the same deployment/order; do not buy another.")
        sleep(min(15, max(0, deadline - clock())))


def merge_txt(client, zone, token):
    identifier = zone + "/TXT/@"
    for _ in range(3):
        current = client.get(identifier, DNS_API)
        p = properties(current)
        records = list(p.get("TXTRecords") or [])
        if any("".join(r["value"]) == token for r in records):
            return
        records.append({"value": [token]})
        body = {"properties": {"TTL": p.get("TTL", 300), "TXTRecords": records}}
        if "metadata" in p:
            body["properties"]["metadata"] = p["metadata"]
        if current and not current.get("etag"):
            raise BootstrapError("Existing TXT record has no ETag; refusing an unconditional DNS overwrite.")
        headers = {"If-Match": current["etag"]} if current else {"If-None-Match": "*"}
        try:
            client.put(identifier, body, DNS_API, headers)
            return
        except ArmError as error:
            if error.status != 412:
                raise
    raise BootstrapError("Concurrent TXT changes prevented a safe merge; retry the existing order.")


def ensure_bootstrap(values, parameters, provision, client, save, sleep=time.sleep, clock=time.monotonic, wait_seconds=1800):
    subscription = values["AZURE_SUBSCRIPTION_ID"]
    group = values.get("APP_DOMAIN_BOOTSTRAP_RESOURCE_GROUP", "")
    domain = parameters.get("domainName", {}).get("value", "")
    if not isinstance(domain, str):
        raise BootstrapError("domainName must be a DNS name string.")
    domain = domain.lower()
    if values.get("APP_GATEWAY_DNS_SUFFIX", domain).lower() != domain:
        raise BootstrapError("Configured DNS suffix differs from the purchase file; no purchases will be attempted.")
    if not re.fullmatch(r"[a-zA-Z0-9_.()-]{1,90}", group) or not re.fullmatch(r"(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}", domain):
        raise BootstrapError("Configure a dedicated bootstrap resource group and a real domainName.")
    scope = f"/subscriptions/{subscription}/resourceGroups/{group}"
    configured_order = values.get("APP_GATEWAY_CERTIFICATE_ORDER_ID")
    if configured_order and not re.fullmatch(
        re.escape(scope) + r"/providers/Microsoft\.CertificateRegistration/certificateOrders/[^/]+", configured_order, re.I
    ):
        raise BootstrapError("Configured certificate order is outside the chosen bootstrap group; no purchases will be attempted.")
    preferred_order = client.get(configured_order) if configured_order else None
    if preferred_order and properties(preferred_order).get("distinguishedName", "").lower() != "cn=*." + domain:
        raise BootstrapError("Configured certificate order does not match domainName; no purchases will be attempted.")
    deadline = clock() + wait_seconds
    rg = client.get(scope, "2024-03-01")
    if not rg:
        if not provision:
            raise BootstrapError("Bootstrap resources are missing. Run azd up with explicit purchase authorization; preprovision/preview never buys resources.")
        require_purchase_inputs(parameters)
        client.put(scope, {"location": values["AZURE_LOCATION"]}, "2024-03-01")
    wait_deployment(client, scope, deadline, clock, sleep)
    vault, order = discover(client, scope, domain)
    if preferred_order and not order:
        raise BootstrapError("Resource discovery has not caught up with the existing order; retry without buying another.")
    if not order:
        if values.get("APP_GATEWAY_CERTIFICATE_SECRET_ID"):
            raise BootstrapError("A certificate secret is already configured but no matching order was found; preserve the manual workflow instead of buying a replacement.")
        if not provision:
            raise BootstrapError("No existing certificate order. Run azd up after authorizing purchases; preview will not create it.")
        require_purchase_inputs(parameters)
        # Also refuse duplicate wildcard orders outside the selected bootstrap group.
        for candidate in client.resources(f"/subscriptions/{subscription}", "Microsoft.CertificateRegistration/certificateOrders"):
            other = client.get(candidate["id"])
            if properties(other).get("distinguishedName", "").lower() == "cn=*." + domain:
                raise BootstrapError("A matching wildcard order already exists. Configure its bootstrap resource group instead of buying another.")
        domain_id = scope + "/providers/Microsoft.DomainRegistration/domains/" + domain
        existing_domain = client.get(domain_id)
        zone = scope + "/providers/Microsoft.Network/dnsZones/" + domain
        for key, record, field in (
            ("existingVerificationTxtRecords", "TXT/@", "TXTRecords"),
            ("existingIssuerCaaRecords", "CAA/@", "caaRecords"),
        ):
            existing = client.get(zone + "/" + record, DNS_API)
            parameters[key] = {"value": properties(existing).get(field, [])}
            parameters["verificationTtl" if record.startswith("TXT") else "issuerCaaTtl"] = {"value": properties(existing).get("TTL", 300)}
            parameters["existingVerificationMetadata" if record.startswith("TXT") else "existingIssuerMetadata"] = {"value": properties(existing).get("metadata", {})}
        parameters["primaryLocation"] = {"value": values["AZURE_LOCATION"]}
        parameters["secondaryLocation"] = {"value": values["AZURE_SECONDARY_LOCATION"]}
        client.register_providers(deadline, clock, sleep)
        client.deploy(group, parameters, vault["id"] if vault else None, bool(existing_domain))
        wait_deployment(client, scope, deadline, clock, sleep)
        vault, order = discover(client, scope, domain)
    if not vault or not order:
        raise BootstrapError("Bootstrap did not produce its vault/order. Inspect the failed deployment; no replacement was purchased.")
    order_id, vault_id = order["id"], vault["id"]
    expected_secret = f"https://{vault['name']}.vault.azure.net/secrets/{SECRET}"
    if values.get("APP_GATEWAY_CERTIFICATE_SECRET_ID", expected_secret).rstrip("/").lower() != expected_secret.lower():
        raise BootstrapError("Configured secret differs from the bootstrap binding; it will not be overwritten.")
    if configured_order and configured_order.lower() != order_id.lower():
        raise BootstrapError("Configured certificate order differs from bootstrap resources; refusing to overwrite it.")
    vp = properties(vault)
    if vp.get("enableRbacAuthorization") is not True or vp.get("publicNetworkAccess") != "Disabled":
        raise BootstrapError("Bootstrap vault must use Azure RBAC and remain publicNetworkAccess=Disabled.")
    binding_id = order_id + "/certificates/gateway"
    txt_done, next_verify, next_bind = False, 0, 0
    while True:
        order = client.get(order_id)
        p = properties(order)
        if p.get("productType") != "StandardDomainValidatedWildCardSsl" or p.get("isPrivateKeyExternal") is not False:
            raise BootstrapError("Existing order must be a paid wildcard with an Azure-managed private key.")
        if p.get("status", "").lower() in ("expired", "revoked", "canceled", "denied") or p.get("provisioningState") in ("Failed", "Canceled"):
            raise BootstrapError("Existing order is failed, expired or revoked; automatic replacement/renewal is forbidden.")
        binding = client.get(binding_id)
        b = properties(binding)
        if binding and (b.get("keyVaultId", "").lower() != vault_id.lower() or b.get("keyVaultSecretName") != SECRET):
            raise BootstrapError("Existing gateway binding points to another vault/secret; it will not be replaced.")
        domain_resource = client.get(scope + "/providers/Microsoft.DomainRegistration/domains/" + domain)
        domain_active = properties(domain_resource).get("registrationStatus") == "Active"
        if p.get("status") == "Issued" and p.get("provisioningState") == "Succeeded" and b.get("provisioningState") == "Succeeded" and domain_active:
            signed = p.get("signedCertificate") or {}
            parse = lambda value: dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
            try:
                before, after = parse(signed["notBefore"]), parse(signed["notAfter"])
            except (KeyError, ValueError, TypeError):
                raise BootstrapError("Issued certificate has invalid validity metadata.") from None
            now = dt.datetime.now(dt.timezone.utc)
            if before.tzinfo is None or after.tzinfo is None or before > now or after <= now + dt.timedelta(days=1) or signed.get("subject", "").lower() != "cn=*." + domain:
                raise BootstrapError("Issued wildcard has invalid coverage/validity; renewal is not automatic.")
            outputs = {
                "APP_GATEWAY_DNS_SUFFIX": domain,
                "APP_GATEWAY_KEY_VAULT_NAME": vault["name"],
                "APP_GATEWAY_KEY_VAULT_RESOURCE_GROUP": group,
                "APP_GATEWAY_CERTIFICATE_SECRET_ID": f"https://{vault['name']}.vault.azure.net/secrets/{SECRET}",
                "APP_GATEWAY_CERTIFICATE_ORDER_ID": order_id,
                "APP_GATEWAY_KEY_VAULT_NETWORK_MODE": "private-endpoints",
            }
            for kind, location in (("PRIMARY", values["AZURE_LOCATION"]), ("SECONDARY", values["AZURE_SECONDARY_LOCATION"])):
                key = f"APP_GATEWAY_{kind}_HOST"
                host = values.get(key) or f"gw-{location}.{domain}"
                if not re.fullmatch(r"[a-z0-9-]+\." + re.escape(domain), host, re.I):
                    raise BootstrapError("Configured gateway host is outside the purchased wildcard.")
                outputs[key] = host
            for key, value in outputs.items():
                if values.get(key) != value:
                    save(key, value)
            print(f"Bootstrap ready: existing wildcard Issued/Succeeded and vault binding Succeeded; expires {after.date()}. No secret/private key downloaded.")
            return outputs
        if not provision:
            raise BootstrapError("Existing bootstrap is not yet Active/Issued/synchronized. Run azd up to resume; preprovision/preview is read-only.")
        if clock() >= deadline:
            raise BootstrapError("Certificate issuance/synchronization timed out. Resume the existing order; do not purchase a replacement.")
        if not domain_active:
            print("Waiting for domain activation; registrant verification email may require action.")
        if (not binding or b.get("provisioningState") == "Failed") and clock() >= next_bind:
            try:
                client.put(binding_id, {"location": "global", "properties": {"keyVaultId": vault_id, "keyVaultSecretName": SECRET}})
            except ArmError as error:
                if error.status not in (403, 409):
                    raise
                print(f"WARNING: Existing vault binding not yet accepted (HTTP {error.status}); waiting for access propagation.")
            next_bind = clock() + 30
        if p.get("status") != "Issued" and domain_active:
            token = p.get("domainVerificationToken")
            if not token:
                raise BootstrapError("Existing order has no domain verification token; inspect it instead of creating another.")
            zone = scope + "/providers/Microsoft.Network/dnsZones/" + domain
            if properties(domain_resource).get("dnsZoneId", "").lower() != zone.lower():
                raise BootstrapError("Registered domain is not delegated to the expected Azure DNS zone.")
            if not txt_done:
                merge_txt(client, zone, token)
                txt_done = True
            if clock() >= next_verify:
                try:
                    client.post(order_id + "/verifyDomainOwnership")
                except ArmError as error:
                    if error.status not in (400, 409):
                        raise
                    print(f"WARNING: Ownership verification pending (HTTP {error.status}); waiting for DNS/issuer propagation.")
                next_verify = clock() + 30
        print(f"Waiting on existing order: {p.get('status')}/{p.get('provisioningState')}; binding {b.get('provisioningState', 'Missing')}.")
        sleep(min(15, max(0, deadline - clock())))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--provision", action="store_true", help="Allow approved bootstrap creation and existing-order DNS/binding verification.")
    parser.add_argument("--wait-seconds", type=int, default=1800)
    args = parser.parse_args()
    if not 1 <= args.wait_seconds <= 7200:
        raise BootstrapError("wait-seconds must be between 1 and 7200.")
    raw = command("azd", ["env", "get-values"])
    values = dict(re.findall(r'^([A-Z][A-Z0-9_]*)="(.*)"\r?$', raw, re.M))
    path = values.get("APP_DOMAIN_BOOTSTRAP_PARAMETERS_FILE")
    if not path:
        print("Domain bootstrap not configured; using the existing/manual certificate workflow.")
        return
    for key in ("AZURE_ENV_NAME", "AZURE_SUBSCRIPTION_ID", "AZURE_LOCATION", "AZURE_SECONDARY_LOCATION"):
        if not values.get(key):
            raise BootstrapError(f"Missing azd value: {key}.")
    path = Path(path)
    if not path.is_absolute():
        path = ROOT / path
    parameters = configured_parameters(path)
    save = lambda key, value: command("azd", ["env", "set", key, value, "--environment", values["AZURE_ENV_NAME"]])
    ensure_bootstrap(values, parameters, args.provision, Azure(values["AZURE_SUBSCRIPTION_ID"]), save, wait_seconds=args.wait_seconds)


if __name__ == "__main__":
    try:
        main()
    except (BootstrapError, OSError, json.JSONDecodeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
