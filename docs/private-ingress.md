# Private ingress guide

This guide covers the opt-in regional Application Gateway and Front Door Private Link architecture, certificate prerequisites, cutover, verification, and rollback. For baseline setup and operations, see the [deployment runbook](runbook.md). Dated deployment evidence is in [history](history.md).

## 9. Opt-in private ingress

### Prerequisites and certificate boundary

Leave `APP_INGRESS_MODE` unset, or set it to `public`, to preserve the original
topology. Do not enable private mode until all prerequisites are ready:

- Own a real public DNS domain and obtain a publicly trusted certificate
  covering both regional gateway hostnames. A wildcard at the correct DNS
  level or two explicit DNS SANs can be used. The managed `azure-api.net`
  certificate and the generated lab backend CA **cannot** be reused.
  Alternatively, provision the separate [paid domain and certificate
  bootstrap](domain-bootstrap.md) first.
- Store that certificate as an **enabled, exportable software-key PFX
  certificate** in an existing, same-subscription Azure Key Vault. Application
  Gateway needs a passwordless PFX with its private key and complete chain.
  Supply a **versionless secret URI**, not a certificate URI or secret value.
  This project never downloads the PFX, private key, or secret value.
- The vault must use Azure RBAC. The default `trusted-services` network mode
  requires its public endpoint, either unrestricted by the firewall or with
  trusted-service bypass enabled. A `Disabled` public endpoint is still rejected
  in that mode. For an existing **issued App Service wildcard order**, explicitly
  select `APP_GATEWAY_KEY_VAULT_NETWORK_MODE=private-endpoints` to use the
  Bicep-owned private path described below; the vault must remain `Disabled`.
  This mode does not change the existing vault or relax its policy.
- The deploying identity needs certificate-metadata read permission, plus
  resource deployment and role-assignment permission at the existing vault.
  Bicep grants the shared gateway identity **Key Vault Secrets User** at that
  vault only. RBAC propagation can require waiting and rerunning provision.
- Select regions supporting Application Gateway and Front Door Private Link.
  West US 3 and Central US are the lab's current regional example; confirm
  availability and quota for your subscription before cutover.

For an imported Key Vault certificate, preparation validates domain syntax, distinct names, the vault/secret binding,
vault RBAC/network settings, certificate enabled/exportable/PFX metadata, DNS
SAN coverage, current validity, more than one day remaining, and a chain trusted
by the local machine. Self-signed certificates and the lab backend CA are
rejected. If intermediates are not locally available, set
`APP_GATEWAY_CERTIFICATE_CHAIN_FILE` to a local PEM bundle containing **public
intermediate certificates only**; this bundle supplements chain construction,
not the root trust store. PowerShell disables automatic certificate downloads;
Bash uses OpenSSL's installed CA store. No private CA is added to either store.

Local trust stores may differ from Front Door's public trust store. The
preflight does not prove PFX secret contents, public-domain ownership, or
revocation status, and does not replace Front Door's mandatory runtime
certificate-name and public-chain validation. Do not disable TLS validation
to work around a failed check.

### Configure names and TLS

The following commands work in either shell after replacing placeholders:

```text
azd env set APP_GATEWAY_DNS_SUFFIX "<owned-domain>"
azd env set APP_GATEWAY_KEY_VAULT_NAME "<existing-vault>"
azd env set APP_GATEWAY_KEY_VAULT_RESOURCE_GROUP "<vault-resource-group>"
azd env set APP_GATEWAY_CERTIFICATE_SECRET_ID "https://<existing-vault>.vault.azure.net/secrets/<certificate-name>"
azd env set APP_INGRESS_MODE private
```

For the private-only vault produced by the [domain bootstrap](domain-bootstrap.md),
additionally set:

```text
azd env set APP_GATEWAY_KEY_VAULT_NETWORK_MODE private-endpoints
azd env set APP_GATEWAY_CERTIFICATE_ORDER_ID "<existing-issued-order-resource-id>"
```

In this mode, preprovision verifies the issued order through management metadata,
not the private secret endpoint. It explicitly reports vault networking as
**planned, not yet proven**. Bicep creates one vault Private Endpoint per region
in a dedicated `vault-private-endpoints` (`.5.0/27`) subnet. Each endpoint gets
its own `privatelink.vaultcore.azure.net` zone and local VNet link in a separate
auxiliary resource group (`rg-<lab-name>-vault-dns-br` / `-us`).
Using distinct groups allows the same zone name to exist twice without sharing
unreachable regional IP addresses. No VNet peering is added. Private Endpoints
and DNS zones are additional billable resources.

Gateway deployment waits for its regional endpoint, DNS zone group, VNet link,
and vault RBAC deployment. Before applying workloads, both publishers perform
a read-only management-plane check of the actual endpoint state and exact
vault/group/approval, local gateway VNet/subnet, endpoint NIC/address, zone group,
single local DNS record, and isolated VNet link. Shared zones, cross-region
addresses, pending/rejected connections and custom VNet DNS are rejected.
This managed mode uses Azure-provided DNS; custom DNS forwarding is not
implemented. Missing or stale outputs fail explicitly; do not copy network
outputs from another environment. These checks do not replace runtime DNS/TLS
verification or the fresh, end-to-end Front Door origin health tests.

### Start again after deleting a lab

Deleting an Azure lab resource group does not remove its local azd environment.
Create a **new environment** rather than copying the old `.env`, TLS directory,
resource IDs, or role-assignment GUIDs. Keep the separately purchased domain,
certificate order and vault unless their removal is explicitly intended.
First verify the domain is `Active`, the order is `Issued/Succeeded`, its exact
vault/secret binding is `Succeeded`, and the vault network setting is as expected.
Do not rerun the purchase bootstrap merely to create another lab.

The following environment setup works in either shell:

```text
azd env new apim-private-lab --subscription "<subscription-id>" --location westus3 --no-prompt
azd env set AZURE_SECONDARY_LOCATION centralus
azd env set APIM_PUBLISHER_NAME "<publisher-name>"
azd env set APIM_PUBLISHER_EMAIL "<publisher-email>"
azd env set AKS_ADMIN_PRINCIPAL_ID "<current-administrator-user-object-id>"
azd env set APP_GATEWAY_DNS_SUFFIX "<existing-owned-domain>"
azd env set APP_GATEWAY_KEY_VAULT_NAME "<existing-vault>"
azd env set APP_GATEWAY_KEY_VAULT_RESOURCE_GROUP "<existing-vault-resource-group>"
azd env set APP_GATEWAY_CERTIFICATE_SECRET_ID "https://<existing-vault>.vault.azure.net/secrets/<existing-secret-name>"
azd env set APP_GATEWAY_CERTIFICATE_ORDER_ID "<existing-issued-order-resource-id>"
azd env set APP_GATEWAY_KEY_VAULT_NETWORK_MODE private-endpoints
azd env set APP_INGRESS_MODE private
```

Leave `AKS_PRIMARY_ADMIN_ROLE_ASSIGNMENT_NAME` and
`AKS_SECONDARY_ADMIN_ROLE_ASSIGNMENT_NAME` unset for new clusters; Bicep generates
fresh deterministic assignments. Preparation creates a new, environment-local
backend CA and keys; do not reuse the deleted lab's private material.
Run the matching preparation and preview commands below before separately
authorizing a deployment. Environment creation/preparation does not create
AKS, APIM, gateways, Private Endpoints or DNS groups. The old local environment
may remain for reference; never print or commit either environment's secrets.
For a fresh deployment, what-if may report the external-vault role assignment
as `Unsupported`: its deterministic GUID depends on the new gateway identity's
principal ID, which does not exist until deployment. Record that limitation
separately from successful Provider validation; it is not proof of an applied
role assignment or permission propagation.

Preparation generates `gw-<AZURE_LOCATION>.<owned-domain>` and
`gw-<AZURE_SECONDARY_LOCATION>.<owned-domain>` and persists them as
`APP_GATEWAY_PRIMARY_HOST` and `APP_GATEWAY_SECONDARY_HOST` after successful
validation. Alternatively, set those two host variables explicitly. Explicit
names take precedence; changing the suffix does not overwrite existing names.
For example, `gw-westus3.<owned-domain>` and `gw-centralus.<owned-domain>`
must both be present in the certificate's SAN coverage.

For an optional intermediate bundle:

```text
azd env set APP_GATEWAY_CERTIFICATE_CHAIN_FILE "<absolute-local-public-PEM-path>"
```

Front Door uses the regional names for the origin Host header and TLS SNI.
Its managed private endpoint reaches the Application Gateway's **private**
frontend. No public A record pointing at the gateway infrastructure IP is
required by this design. Regular preparation requires an issued certificate;
the optional [preup bootstrap](domain-bootstrap.md) can perform issuance/domain
validation before those preparation gates.

### Cutover, explicit approval, and verification

**This is not a zero-downtime migration.** Switching the existing APIM service
from External to Internal can interrupt the old public-origin path before
private origins are approved and healthy. Use a maintenance window, preserve
the current configuration, review preview, and obtain a rollback decision
before applying changes.

PowerShell:

```powershell
pwsh -File .\scripts\powershell\Prepare-Lab.ps1
pwsh -File .\scripts\powershell\Provision-Lab.ps1 -Preview
# Explicit infrastructure cutover; startup still requires -StartResources.
pwsh -File .\scripts\powershell\Provision-Lab.ps1
# Inspect requests in both gateway resources before confirming each approval.
pwsh -File .\scripts\powershell\Connect-PrivateOrigins.ps1 -Approve
pwsh -File .\scripts\powershell\Deploy-LabApi.ps1
pwsh -File .\scripts\powershell\Test-Origins.ps1
```

Bash:

```bash
bash scripts/bash/Prepare-Lab.sh
bash scripts/bash/Provision-Lab.sh --preview
# Explicit infrastructure cutover; startup still requires --start-resources.
bash scripts/bash/Provision-Lab.sh
bash scripts/bash/Connect-PrivateOrigins.sh --approve
bash scripts/bash/Deploy-LabApi.sh
bash scripts/bash/Test-Origins.sh
```

On the first deployment, Front Door requests normally await owner approval.
Front Door can return a null/absent Private Link status while the gateway
reports a matching `Pending` request. The helpers expose this as `Initializing`.
The explicit workflow can approve a uniquely matched pending gateway request.
The Front Door projection can remain null after that approval. In that case,
the gate accepts the distinct state `ApprovedAtGateway` only when the exact
unique connection is `Succeeded/Approved`, the origin is `Succeeded/Enabled`,
and its gateway, private frontend group, hostname, Host header, region, request
marker and mandatory TLS validation match the environment. The helper explicitly
warns that it is using gateway-side approval evidence, not proof of runtime
health. Nonempty Front Door states are authoritative: `Pending` is still waited
on, and `Rejected`/`Disconnected` are never overridden by a gateway approval.
If no matching request has appeared yet, it waits without creating or approving
anything. Rejected, disconnected, unknown or ambiguous requests stop the check.
The postprovision publisher **intentionally fails before applying workloads**
until both origin connection approvals are verified. That failure does not roll
back provisioned infrastructure. After approving the intended requests, rerun
the publisher as above. Running `Connect-PrivateOrigins` without the approval
flag is read-only and fails if either origin is not approved.
Approval alone does not establish a working route: the publisher still requires
successful rollout, global smoke tests and fresh per-origin health metrics.

The approval helper checks the selected lab subscription/resource group, both
gateway IDs, the private frontend, origin hostnames and TLS-validation setting.
It only proposes pending requests bearing the exact
`apim-lab:<ARM-guid-of-lowercase-Front-Door-profile-resource-ID>`
marker (45 characters, below Azure's 140-character request-message limit),
with an explicit confirmation
per connection. Legacy full-resource-ID markers remain recognized for existing
requests; new requests and approval descriptions use the compact hash.
**The marker is not authentication**: verify the request
belongs to the intended Front Door profile before confirming. Unrelated or
ambiguous requests are never auto-approved; rejected/disconnected origins
require investigation. For previously verified automation, PowerShell
`-Approve -Confirm:$false` and Bash `--approve --yes` bypass the interactive
confirmation. Do not use them based only on the marker.

### Network, TLS, and operational behavior

- Each regional VNet gets dedicated `application-gateway` (`.3.0/24`) and
  `gateway-private-link` (`.4.0/27`) subnets, plus the reserved
  `vault-private-endpoints` (`.5.0/27`) subnet for managed private vault access.
  No inter-region VNet peering is introduced.
- Application Gateways have only a **private HTTPS application listener**.
  The template retains a Standard public IP/frontend for v2 infrastructure
  compatibility, with **no HTTP or HTTPS listener attached to it**. This is
  private application ingress, not a claim that no public IP exists.
- The Application Gateway NSG permits HTTPS from its Private Link subnet,
  required GatewayManager management traffic, and Azure Load Balancer probes;
  other port 80/443 ingress is denied.
- APIM uses Internal mode. Its NSG admits application HTTPS from the regional
  gateway subnet and retains required APIM/Azure platform exceptions.
  APIM public infrastructure IPs and management dependencies remain; they
  are not public API gateway listeners in Internal mode.
- Application Gateway uses the local APIM private VIP as its backend, with
  the regional APIM hostname for HTTPS Host/SNI and platform certificate
  validation. This avoids relying on public DNS to reach APIM. The platform
  `/status-0123456789abcdef` probe checks APIM availability.
- Front Door still probes **`HEAD /lab/health/ready`**. Those probes traverse
  Private Link, Application Gateway, APIM, and the local AKS HTTPS workload.
  Regional locality, fresh 100% metric evidence, failover timing, restoration
  checks, and the global `X-Azure-FDID` policy remain enforced.
- APIM-to-AKS uses the existing private DNS, CA, service, and source-range
  restrictions. The lab backend CA and gateway public certificate have
  separate purposes and rotation procedures.
- New outputs identify the ingress mode, both gateway resource IDs, and
  active Front Door origin hosts/group. Older public environments without
  these outputs remain supported. Changing mode without reprovisioning
  cannot reuse the other mode's origin-health evidence.

### Rollback and cleanup

Set `APP_INGRESS_MODE` back to `public`, review preview, and reprovision to
restore APIM External mode and the public origin group. That transition can
also interrupt service. **Changing one environment variable does not perform
a rollback.**

Successful private preparation also persists `APP_GATEWAY_NETWORK_MODE=retain`.
Keep that value during rollback so the VNet update preserves subnets still in
use by retired gateways; without it Azure would reject their removal.
Keep `APP_GATEWAY_KEY_VAULT_NETWORK_MODE=private-endpoints` as well if that path
was provisioned: with network retention, Bicep retains the two vault endpoints,
DNS zones/links and auxiliary DNS groups. Before eventual cleanup, remove vault
endpoints before their occupied VNet subnets, and remove their DNS groups only
after confirming no remaining links/dependencies. Do not remove the shared,
separately purchased domain/order/vault while another environment uses them.
Direct Bicep callers must likewise use `gatewayNetworkMode=retain` while those
gateways exist. Only return the setting to `auto` after explicitly deleting
the retired gateway/Private Link resources and verifying no remaining subnet
dependencies.

Deployments are incremental. Switching modes does **not** delete previous
origin groups, Application Gateways, their IPs/identity, Private Link
connections, subnets, or external-vault role assignments. Unused gateways can
continue billing. After the selected path is proven healthy, inspect and
explicitly clean up only the retired resources and assignments. Remove
retired gateways before attempting to remove their in-use subnets.

The historical public-topology results are documented in [history](history.md). Local validation is not evidence that private ingress has been provisioned, approved, or failover-tested in Azure.
