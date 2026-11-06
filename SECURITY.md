# Security policy

## Scope and support

This repository is an experimental Azure infrastructure lab, not a supported
production blueprint. Security fixes target the latest version on `main`;
older commits do not receive separate fixes. The sample API is intentionally
anonymous and must not serve sensitive data.

## Report a vulnerability privately

Use [GitHub private vulnerability reporting](https://github.com/seilorjunior/one-apim-multiregion/security/advisories/new).
Do not disclose vulnerabilities, credentials, personal information, or live
infrastructure identifiers in a public issue or pull request. If private
reporting is unavailable, do not post the details publicly; wait until a
private reporting channel is available.

Include the affected commit, expected impact, and minimal reproduction steps
using placeholders or an isolated environment. Never include secret values,
private keys, registrant contacts, raw environment files, or deployment logs.
There is no guaranteed response time or service-level agreement.

## If a secret is exposed

Revoke or rotate it immediately in the issuing system. Removing a file or
rewriting Git history does not invalidate a credential or remove copies from
clones, forks, caches, pull requests, or workflow artifacts. Notify the
maintainer privately and review affected access and audit logs.

## Deploy safely

- Use an isolated subscription or resource group and least-privilege access.
- Keep local settings and TLS material in the ignored `.azure/` directory.
- Supply domain-registration contacts only through protected local files.
- Review billable provisioning, domain purchases, renewals, and cleanup.
- Review authentication and abuse controls before sharing a running endpoint.
- Do not add Azure credentials or deployment privileges to pull-request CI.

See the [runbook](README.md#lab-costs-and-limitations) for cost, topology,
certificate, and operational limitations.
