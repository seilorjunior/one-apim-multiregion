# Live and historical evidence

This page records dated Azure observations. They are snapshots, not guarantees of current health, production capacity, or an SLA. Follow the relevant guide for repeatable procedures.

### Validation status and evidence boundaries

| Evidence | What it establishes | What it does not establish |
|---|---|---|
| November 4, 2026 private-model preview | Azure accepted the corrected Private Link marker and generated a preview | Applied resources, runtime connectivity, or private failover |
| November 5, 2026 live recovery | Both stopped Application Gateways were started; both APIM backends were Healthy; GET/HEAD readiness and 20 API samples passed across both regions | A completed strict per-origin metric gate or a private failover run |
| November 5, 2026 readiness revalidation | Both AKS/gateways Running/Succeeded, actual nodes/workloads ready, vault/certificate/Private Link gates passed; another 20 API samples and GET/HEAD passed; both origins passed fresh Minimum 100% evidence through the 13:40 UTC completed bucket | Private failover, an explanation of the earlier metric delay, or permanent health |
| November 5, 2026 bounded k6 run | 2 VUs for 60 seconds; 73 HTTP 200 responses across both regions; 219/219 checks; p95 1114.64 ms and p99 approximately 1.36 seconds; no sampled HTTP or response-validity errors | Production capacity, availability during disruption, or permanent latency guarantees |
| November 5, 2026 private-path failover runs | Observed transitions in both directions; 2 sampled timeouts stopping West US 3 and 8 stopping Central US; original two replicas restored; fresh strict origin recovery and smoke checks passed after each run | Impact-free failover, an actual Azure regional outage, exact RTO, or all-client recovery |
| Local Bicep/script and cross-shell tests | Offline contracts and topology checks passed | Azure capacity, live permissions, or data-plane health |
| Existing paid certificate observation | Domain active, wildcard issued, exact vault binding synchronized | Gateway retrieval or future renewal |
| November 3, 2026 public-mode failover | Historical public-origin workload test | Results for the new private path |

The private path has live API, gateway-backend and fresh regional metric
evidence. The earlier revalidation's 20 client samples all selected Central US; the
independent per-origin metric gate established current health in both regions.
The later private failover runs are documented under
[measured private-path failover](#measured-private-path-failover).
Do not treat successful client samples alone as proof that all Front Door
origins are healthy.

On November 5, the AKS clusters were Running and workloads had rolled out,
but both Application Gateways were `Stopped/Succeeded`, causing HTTP 504.
Starting those existing gateways restored API responses without a redeployment,
new purchases or changes to Private Link approvals. Gateway access logs after
the recovery boundary (`2026-11-05T12:59:31Z`) showed successful HTTP 200
`Edge Health Probe` readiness requests in both regions. The separate Azure
Monitor check had not established two fresh completed buckets at Minimum
100% during that initial validation window. A later read-only revalidation
passed the unchanged strict gate for both origins, through the completed
13:40 UTC bucket. No reporting-delay root cause was established and the
acceptance threshold was not relaxed.

### Historical public-mode evidence

The retired `apim-west-lab` environment used **restricted public APIM origins**,
not the current private Application Gateway path. Its November 3, 2026 results
remain available as historical evidence:
[PNG](../diagrams/historical-public-failover.png) |
[Vector SVG](../diagrams/historical-public-failover.svg).

Do not treat that drawing, its resource names or its results as current
private-environment deployment evidence.

The historical real run on **November 3, 2026**, before the stronger acceptance
checks below were added, completed with exit code `0`:

| Simulated workload failure | Serving region | Time to five consecutive responses | Failed samples |
|---|---|---|---|
| West US 3 API stopped | Central US | 42 seconds | 0 |
| Central US API stopped | West US 3 | 102 seconds | 3 timeouts |

These elapsed times include Run Command overhead and sampling, not exact RTO.
The first case demonstrated continued service from Central US, which was
already serving the initial samples; it does not independently measure a
traffic transition. Both clusters finished with two replicas, successful
rollouts, verified removal of temporary role assignments, and a passing final
smoke test. The three timeouts show that failover was not impact-free.

### Existing paid certificate: observed bootstrap result

The identifiers in this observation are anonymized documentation examples,
not resources available to repository readers.

On November 4, 2026, the lab domain (shown here as `example.com`) was confirmed
`Active` and the certificate order (shown as `origin-wildcard-example`) was
confirmed `Issued/Succeeded`, with its `gateway` binding synchronized to the
vault (shown as `kv-origin-example`) / `gateway-origin`.
The GoDaddy wildcard covers both regional gateway names. Public certificate
bytes were inspected without downloading the secret or private key.
The issued leaf is valid from **2026-11-04T16:28:09Z through
2027-05-21T16:28:09Z (198 days)**, not 360 days. The vault remained
`publicNetworkAccess=Disabled`; this demonstrates the tested issuer operation,
not gateway data-plane connectivity or future reissuance behavior.

The initial deployment failed because order creation included a read-only
`certificates` collection; Bicep now models the binding as a separate child.
The existing order, binding and verification were completed through scoped ARM
operations rather than by repurchasing the domain or replacing the vault.
For a retry, inspect existing resources first, reuse their deterministic IDs,
preserve unrelated TXT records, and verify DNS before requesting ownership
verification. Do not submit a second paid order to recover a transient error.
This observed result is not proof of a completed private lab deployment.

Both automatic renewals remain disabled. Retaining service for 360 days requires
an explicitly approved reissue/renewal plan before the leaf expires; an annual
paid product does not provide a single 360-day leaf or unattended coverage.
No new purchase or renewal is needed merely to prepare a fresh lab now.

If switching back to an imported Key Vault certificate, clear
`APP_GATEWAY_CERTIFICATE_ORDER_ID` so the existing certificate-object,
SAN, PFX/exportability metadata, and local-chain checks apply instead.
A fresh environment may select `APP_INGRESS_MODE=private` before bootstrap;
the `preup` stage must finish before the regular preparation gates can pass.
For existing public environments, follow the [private ingress guide's
explicit cutover](private-ingress.md#cutover-explicit-approval-and-verification).
In either case, complete Private Link approval and fresh end-to-end checks
before declaring the private deployment healthy.

Deleting Azure resources is not a guaranteed refund/cancellation of domain or
certificate purchases. Retain the issuer's vault access while renewal/rekey
is needed, and manage cancellation/renewal through the registrar/issuer.
Offline tests do not purchase domains or issue certificates. Verify live
registration and issuance separately; successful template validation is not
proof that the complete bootstrap can finish.

### Measured private-path failover

The existing failover scripts interrupt only `lab-api` replicas in one cluster,
not the AKS cluster, gateway, network or entire Azure region. Both origins must
pass strict preflight health before interruption. Run each direction
sequentially; restoration and fresh strict recovery must finish before the
next experiment.

```powershell
pwsh -File .\scripts\powershell\Test-Failover.ps1 -StopRegion Primary `
  -ReportPath .\test-results\failover-primary.json
pwsh -File .\scripts\powershell\Test-Failover.ps1 -StopRegion Secondary `
  -ReportPath .\test-results\failover-secondary.json
```

```bash
bash scripts/bash/Test-Failover.sh --stop-region Primary \
  --report-path test-results/failover-primary.json
bash scripts/bash/Test-Failover.sh --stop-region Secondary \
  --report-path test-results/failover-secondary.json
```

Failover tests persist bounded, sanitized JSON reports under
`test-results/failover-<runId>.json`. Override the destination with PowerShell
`-ReportPath` or Bash `--report-path`; existing files are not overwritten.
Reports distinguish observed transition from continued service and record
request samples, observer timing, replica restoration, and fresh strict
recovery outcomes, even after test or cleanup failures. Timing includes Run
Command and instrumentation overhead, not exact RTO. Recovery does not force
client moveback. Forced process termination or unwritable storage can prevent
final reporting. A failure report is not a successful resilience result;
inspect restoration states and recover manually if they failed.

#### November 5, 2026 live results

Versioned execution reports: [Primary](../test-results/live-failover-primary.json)
and [Secondary](../test-results/live-failover-secondary.json). These two reviewed
snapshots are committed explicitly; other generated test results remain ignored.

Both sequential runs used the existing private path and recorded
`ObservedTransition`, not merely continued service. The Primary run completed
at `2026-11-05T17:49:53Z`; the Secondary run completed at
`2026-11-05T18:14:55Z`. Every stage, including replica verification, fresh strict
origin health and recovery smoke, passed.

| Interrupted workload | Surviving region | Sampled timeouts | First successful survivor observed | Five-response survivor window observed |
|---|---|---|---|---|
| West US 3 | Central US | 2 | 67.88 seconds | 97.46 seconds |
| Central US | West US 3 | 8 | 192.52 seconds | 221.82 seconds |

These timings start before the scale operation and include Azure Run Command,
polling, sequential HTTP requests, validation and reporting overhead. They are
not exact outage duration or RTO. The timeouts demonstrate that the observed
failover was **not impact-free**. Each workload was restored to two replicas;
the final Kubernetes check found two ready pods on distinct nodes per region,
with PDB `minAvailable: 1` and one allowed disruption. Both origins passed fresh
completed-bucket Minimum 100% evidence through `2026-11-05T18:06:00Z`.

The bounded k6 run was separate from the disruption experiments: 42 responses
came from Central US and 31 from West US 3, with no failed checks. Its p99 value
above comes from the evaluated threshold console; the scenario now also
exports p99 numerically in future JSON summaries. These are dated lab
observations, not continuous monitoring or a production SLA.
