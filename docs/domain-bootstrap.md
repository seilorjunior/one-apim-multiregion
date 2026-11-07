# Domain and certificate bootstrap guide

This guide covers the optional, purchase-gated domain registration and certificate bootstrap. It can incur real charges; review the explicit authorization and cost gates before use. For private ingress prerequisites, see the [private ingress guide](private-ingress.md); general deployment steps are in the [runbook](runbook.md). Dated issuance observations are in [history](history.md).

## 10. Optional paid domain and certificate bootstrap

[domain-bootstrap.bicep](../infra/domain-bootstrap.bicep) is a **separate resource-group-scoped
deployment**. Plain `azd provision` only checks/reuses its existing resources;
it never submits the paid bootstrap deployment. The bootstrap is not part of the APIM
External-to-Internal cutover. It can now be orchestrated automatically by the
optional `azd up` **preup** hook, before private infrastructure provision.
Without that opt-in, existing/manual certificate behavior is unchanged. Its matching
[domain-bootstrap.parameters.json](../infra/domain-bootstrap.parameters.json) contains no chosen domain, contact
data, or legal acceptance, and sets **`authorizePurchases=false`**. Every
resource is conditional on that explicit authorization; defaults create
**nothing**, including no DNS zone or Key Vault.

### Enable automatic bootstrap in the azd workflow

Set these two values after preparing the protected parameter file described below:

```text
azd env set APP_DOMAIN_BOOTSTRAP_PARAMETERS_FILE "<protected-local-parameters-path>"
azd env set APP_DOMAIN_BOOTSTRAP_RESOURCE_GROUP "<dedicated-domain-resource-group>"
```

For the current environment, the protected file is
`.azure/domain-bootstrap.multi-region-api-lab.parameters.json` and the group
is `rg-domain-multi-region-api-lab`. Keep `authorizePurchases=false` to reuse
the already issued certificate. No new domain/order is necessary for another lab.
The optional shared bootstrap engine requires **Python 3.9+**, including on
Windows. The shared readiness engine uses the same standard-library-only
dependency, even when certificate bootstrap is not configured.

The automated sequence is:

1. `azd up` runs `Sync-DomainBootstrap` in its `preup` hook. It discovers the
   dedicated group's domain, vault and order, checks any explicitly configured
   order ID, and reuses an existing `Active` / `Issued/Succeeded` /
   synchronized binding without Azure mutations or purchase authorization.
2. If resources are missing, creation is blocked unless the **protected file**
   explicitly contains `authorizePurchases=true`, real contacts/registrar
   acceptance, and the tenant issuer service principal object ID. Review
   current prices/terms before changing that flag. Renewals remain false.
   The engine refuses matching wildcard orders found elsewhere in the
   subscription instead of buying a duplicate in a different group.
3. Before any paid deployment, Azure **Provider validation** and what-if must
   succeed. Missing bootstrap resource providers are registered only in the
   explicitly authorized creation path, with a bounded wait. The preview must
   identify one new order and the expected vault;
   destructive, unsupported or conflicting changes block submission.
   The stable `domain-bootstrap-azd` deployment is resumed if already running,
   and a direct order lookup is repeated immediately before submission.
4. The engine publishes/merges root verification TXT with ETag concurrency
   protection, retaining unrelated values, TTL and metadata. It requests
   verification on the **existing order**, retries DNS/issuer propagation,
   and waits for domain activation, `Issued/Succeeded` and the exact vault
   binding's `Succeeded` state. The default overall wait is 30 minutes;
   individual requests have bounded timeouts. Registration email verification
   can still require registrant action.
5. Only after these checks does it persist non-secret gateway/domain/vault/order
   references into the selected azd environment. It never downloads the PFX,
   secret value or private key. The regular preprovision certificate/network
   gates then run before APIM/gateway deployment.

**Preview safety:** azd also executes `preprovision` hooks during
`azd provision --preview`. Therefore that hook is strictly read-only against
Azure for certificate bootstrap, even if the purchase flag is true.
It can resolve existing references locally, but missing/pending certificates
stop preview with an actionable error instead of being purchased or modified.
`azd provision` likewise only reuses/verifies this bootstrap; use `azd up` for
an initial automated purchase. Do not move purchasing into `preprovision`.
The non-preview `Provision-Lab` wrappers also explicitly run the bootstrap
before cluster startup; their preview branches never do so.

For a separate certificate-only run, without provisioning the lab:

```powershell
pwsh -File .\scripts\powershell\Sync-DomainBootstrap.ps1 -Provision -WaitSeconds 1800
```

```bash
bash scripts/bash/Sync-DomainBootstrap.sh --provision --wait-seconds 1800
```

Omit `-Provision` / `--provision` for read-only reuse/checks. Timeouts or
failed orders never trigger replacement/renewal. Inspect Azure state, then
rerun against the same group/order; correct failed prerequisites rather than
buying another certificate. Restore the local purchase flag to false after
the approved purchase. Raw provider/CLI errors are not forwarded because
they may contain registrant data; inspect the scoped Azure deployment/activity
log when an operation reports an error.

Private Link approval for the Front Door origins remains a separate explicit
owner action after infrastructure provision, as documented in the
[private ingress guide](private-ingress.md).
Bootstrap automation does not silently approve those connections.

When authorized with complete real parameters, the template provisions:

- An Azure DNS public zone and a paid
  `Microsoft.DomainRegistration/domains` registration delegated to that zone.
  This is actual registration, not just an unowned DNS zone.
- A dedicated Standard Key Vault with Azure RBAC, soft delete, purge
  protection, **public network access Disabled**, and network default-deny with
  trusted-service bypass. Gateway access uses the explicit private-endpoints
  mode in the [private ingress guide](private-ingress.md); the issuer and the
  gateway have different access paths.
- Key Vault Secrets Officer for the tenant's CertificateRegistration service
  principal, scoped only to this dedicated vault.
- A paid `Microsoft.CertificateRegistration/certificateOrders` order for
  **`*.domainName`**, using `StandardDomainValidatedWildCardSsl`, an
  Azure-managed private key, and a separately deployed
  `certificateOrders/certificates` child resource for the Key Vault secret
  binding. The order's `certificates` collection is read-only during order
  creation and must not be sent in the create request.
- Root TXT verification and GoDaddy CAA/issuewild records. The wildcard
  covers `gw-westus3.domainName` and `gw-centralus.domainName`, not arbitrary
  deeper subdomains.
- Non-secret outputs for the regional names, vault, versionless certificate
  secret URI, and certificate-order resource ID. No PFX/private key is
  downloaded, emitted as an output, or committed.

### Purchase gate and preparation

**No purchase is authorized by the example files.** Before enabling the gate:

1. Select an available domain and verify that the subscription can buy
   App Service domains/certificates. Credit-based and free-trial subscriptions
   may be ineligible; an enabled subscription alone is not proof of eligibility.
   Check inherited Azure Policy assignments before purchasing. A `Modify`
   policy can force the vault's public network access to `Disabled` even when
   template validation succeeds. Verify the live vault configuration and
   Activity Log; do not override organizational controls or relax certificate
   preflight checks. This template now declares `Disabled` itself rather than
   depending on an inherited policy to mutate it. Issuer synchronization and
   gateway certificate retrieval must be verified separately; successful
   issuance does not establish gateway private connectivity.
2. Obtain and explicitly approve current domain-registration and wildcard
   certificate prices, taxes, and registrar terms. DNS/Key Vault charges are
   additional. Do not treat template validation or deployment preview as a
   price quote.
3. Use a dedicated resource group per domain, separate from the disposable
   azd lab, so retiring the lab does not implicitly remove the domain's DNS.
4. Copy the parameter example to a protected, **non-versioned** local file,
   for example under `.azure/<environment>/`. Provide the actual domain and
   accurate ICANN contact information. `registrationContact` and
   `domainPurchaseConsent` are secure objects, not code constants.
   The contact object uses `nameFirst`, `nameLast`, `email`, `phone`, and
   `addressMailing` with `address1`, `city`, `state`, `postalCode`, and `country`.
   The registrar requires `phone` in `+<country-code>.<national-number>` format,
   with a dot after the country code and no hyphens or parentheses.
   For Brazilian contacts (`country: BR`), format `postalCode` as `NNNNN-NNN`.
   The contact email must not use `microsoft.com` or the domain being purchased.
   The same contact is used for registrant/admin/billing/technical roles.
5. Supply actual `agreementKeys`, `agreedAt`, and `agreedBy` from the reviewed
   registrar agreement/acceptance. Never fabricate contact information,
   agreement identifiers, an acceptance timestamp, or an IP address.
   Do not send contact information or the private parameter file in chat.
6. Resolve the CertificateRegistration **service principal object ID** in the
   selected Entra tenant, not its application ID:

   ```text
   az ad sp show --id f3c21649-0979-4721-ac85-b0216b2cf413 --query id --output tsv
   ```

   Put the result in `certificateIssuerPrincipalId`. If the service principal
   is absent or lookup is denied, resolve that prerequisite with the tenant
   administrator; do not substitute the application ID or another identity.

`autoRenewDomain` and `autoRenewCertificate` default to **false** to avoid
unapproved renewal charges. Configure and fund renewal explicitly before
expiry if the deployment will be retained. Do not assume that a one-year
certificate order means each issued certificate has a one-year validity
period; issuance limits and renewal rules are controlled by the issuer.
Domain privacy is enabled by default where supported; verify TLD eligibility.

Compile locally with `bicep build infra/domain-bootstrap.bicep`.
After price/terms approval and preparation of the real secure parameters, use
Azure deployment validation/what-if against the **domain resource group**
before a separately authorized deployment. Only that real deployment uses
`authorizePurchases=true`; the repository default must remain false.
Creating a resource group, registering providers, changing Entra permissions,
or submitting a certificate order are not performed by local compilation.

### Issuance and connection to private ingress

A successful ARM deployment **is not proof of certificate issuance**.
Domain registration, registrar delegation, DNS propagation, CA validation,
and Key Vault RBAC propagation can take time. Domain registration/contact
verification emails may require action by the registrant. For a fresh private
environment, finish bootstrap before provisioning the lab. For an existing
public environment, do not cut over APIM to Internal until issuance and
binding checks pass.

After confirming DNS propagation, the certificate-order ownership-verification
operation can be requested explicitly:

```text
az rest --method post --url "https://management.azure.com/<certificate-order-resource-ID-without-leading-slash>/verifyDomainOwnership?api-version=2024-11-01"
```

This verifies an **existing order**; it is not a replacement for approving
the initial purchase. Query the actual order until its status is `Issued`,
its provisioning state is `Succeeded`, and the configured vault binding
reports `Succeeded`. Investigate errors rather than recreating paid orders.
If the issuer vault grant has not propagated, wait and retry the existing
deployment/order instead of purchasing another certificate.

Set the following azd values using the completed bootstrap's outputs:

| azd value | Bootstrap output |
|---|---|
| `APP_GATEWAY_DNS_SUFFIX` | `APP_GATEWAY_DNS_SUFFIX` |
| `APP_GATEWAY_PRIMARY_HOST` | `APP_GATEWAY_PRIMARY_HOST` |
| `APP_GATEWAY_SECONDARY_HOST` | `APP_GATEWAY_SECONDARY_HOST` |
| `APP_GATEWAY_KEY_VAULT_NAME` | `APP_GATEWAY_KEY_VAULT_NAME` |
| `APP_GATEWAY_KEY_VAULT_RESOURCE_GROUP` | `APP_GATEWAY_KEY_VAULT_RESOURCE_GROUP` |
| `APP_GATEWAY_CERTIFICATE_SECRET_ID` | `gatewayCertificateUri` |
| `APP_GATEWAY_CERTIFICATE_ORDER_ID` | `APP_GATEWAY_CERTIFICATE_ORDER_ID` |

App Service Certificates store the PFX as a **Key Vault secret**, not
necessarily a Key Vault certificate object. With the order ID configured,
both preparation scripts therefore check authenticated Azure management
metadata: same-subscription order, paid wildcard product, Azure-managed key,
`Issued/Succeeded` status, exact vault/secret binding, successful
synchronization, signed subject coverage, and current validity with more
than one day remaining. They do **not** fetch the secret to inspect its PFX.
This branch trusts the Azure certificate-registration issuer's attestation
and does not perform the imported-certificate local X.509 chain check.
Some order responses include public PEM in `signedCertificate.rawData`; those
bytes are public certificate data, not a PFX or private key. Their presence does
not prove that a gateway can retrieve its configured secret.
Front Door still performs mandatory public
chain/name validation at runtime; no validation setting is disabled.

### Existing paid certificate: observed bootstrap result

The dated certificate issuance observation is documented in [history](history.md). Do not treat it as proof of gateway connectivity or future reissuance behavior.
