# Contributing

This is a non-production Azure lab. Open an issue for a bug or proposed change
before undertaking a large contribution. Report vulnerabilities through the
[private security reporting process](SECURITY.md), not public issues.

## Local validation

Install the prerequisites in the [runbook](README.md#1-prerequisites).
Install the offline test dependencies:

```powershell
python -m pip install -r tests/requirements.txt
npm ci
```

From the repository root, run the same checks as CI:

```powershell
pwsh -File .\tests\Test-Local.ps1
python -m xmlrunner discover -s tests -p 'test_*.py' -v -o test-results
npm run test:diagrams
npm run diagrams:check
```

These are offline checks; they do not prove live Azure readiness. Do not run
`azd up`, purchase resources, approve Private Link, or disrupt a deployment
without the owner's explicit permission and cost approval.

## Pull requests

- Keep changes focused and explain the intended behavior and compatibility.
- Preserve equivalent PowerShell and Bash behavior and shared Python contracts.
- Add relevant offline tests and update directly related documentation.
- Use reserved domains such as `example.com` and synthetic data in examples.
- Run `npm run diagrams` whenever an SVG changes, and commit its PNG exports.
- Never commit environment files, credentials, private keys, real registrant
  contacts, or raw deployment output. Review generated reports before sharing.
- Run a local secret scanner against changes and Git history before publishing.

CI also runs checksum-pinned Gitleaks against full Git history on pushes and
pull requests, with redacted output and no external scanning service or license
key. A detected secret fails the workflow; do not suppress a real credential.
Revoke exposed credentials before following the [security policy](SECURITY.md).

The sample API remains anonymous for lab demonstrations; changes to its
authentication contract require an explicit design decision and updated tests.
Contributions are provided under the repository's [MIT license](LICENSE).
