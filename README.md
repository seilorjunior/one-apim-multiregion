# Private multi-region API lab: Front Door, Application Gateway, APIM, and AKS

Infrastructure as code with **Azure Developer CLI (azd) + Bicep** for one
classic Premium APIM service with two regional gateways and two private AKS
clusters. The documented environment uses West US 3 + Central US, private
regional ingress, and private Key Vault access. This is a lab, not a
production blueprint.

**Compatibility boundary:** the Bicep default remains `public`; the private
model requires explicit environment settings. Reading this documentation
does not change defaults or migrate an existing deployment.

## Architecture

![Front Door Premium and WAF reach regional Application Gateways through approved Private Link, then Internal APIM and private AKS](diagrams/private-ingress.svg)

Front Door Premium is the public client entry point. Its approved Private
Link connections reach private regional Application Gateway listeners, then
one Internal-mode APIM service and each region's private AKS workload. The
regional VNets are not peered. Gateway infrastructure public IPs and AKS
outbound connectivity still exist; private application ingress does not mean
all infrastructure is private.

The backward-compatible template default is the [public-origin
architecture](diagrams/public-origins.svg). It uses the two APIM regional
gateways as restricted public Front Door origins. See the [mode comparison and
limitations](docs/runbook.md#mode-comparison) before choosing a mode.

## Start here

- **Existing prepared private environment:** use the [quick
  start](docs/runbook.md#quick-start-existing-prepared-private-environment).
- **New deployment:** begin with [prerequisites and environment
  configuration](docs/runbook.md#1-prerequisites).
- **Provisioning, validation, API tests, failover, cleanup, alerts, and load
  testing:** [deployment and operations runbook](docs/runbook.md).
- **Private ingress setup, cutover, verification, and rollback:** [private
  ingress guide](docs/private-ingress.md).
- **Optional paid domain and certificate bootstrap:** [domain and certificate
  guide](docs/domain-bootstrap.md). Its default creates no resources; purchases
  require explicit authorization.
- **Dated Azure observations and historical results:** [live and historical
  evidence](docs/history.md). Evidence is time-bounded and is not a guarantee
  of current health, production capacity, or an SLA.
- **Architecture diagrams:** [diagram catalog](diagrams/README.md).

## Important boundaries

The lab has significant ongoing costs, including two classic APIM Premium
units, Front Door Premium, AKS nodes, and—when using private ingress—two
Application Gateways and related networking. Review the [costs and
limitations](docs/runbook.md#lab-costs-and-limitations) before provisioning.
The sample API is intentionally anonymous and must not serve sensitive data.
Do not advertise an unattended lab endpoint; review authentication, abuse
controls, and charges before sharing a deployment.

Publishing or cloning this repository does not grant access to an existing
Azure environment. Domain names, certificate identifiers, and deployment
evidence in the documentation are examples or anonymized snapshots. Use a
domain you own and an appropriately issued certificate for a real deployment.
Keep environment files, private keys, registrant contacts, and raw deployment
output out of commits, issues, and workflow artifacts.

See the [MIT license](LICENSE), [contribution guide](CONTRIBUTING.md), and
[security reporting policy](SECURITY.md).
