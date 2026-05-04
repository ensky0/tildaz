# Security Policy

## Reporting a vulnerability

TildaZ uses GitHub's **Private Vulnerability Reporting** for security issues.
Please do not open public issues for suspected vulnerabilities.

To report:

1. Open the repository's **Security** tab → **Report a vulnerability**
2. Describe the impact, affected version, and reproduction steps
3. Submit — only repository maintainers can read the report

Direct link: https://github.com/ensky0/tildaz/security/advisories/new

## Supported versions

TildaZ is a single-maintainer hobby project. Only the **latest release** on
the `main` branch receives security fixes. Older releases are not patched.

## Response expectations

This is a best-effort project. The maintainer aims to:

- Acknowledge a report within **7 days**
- Provide a triage decision (accept / not-applicable / need more info) within
  **14 days** of acknowledgement
- Ship a fix in the next release when a vulnerability is confirmed

These targets are not guarantees; response time depends on maintainer
availability.

## Scope

**In scope**

- The `tildaz.exe` (Windows) and `TildaZ.app` (macOS) binaries as shipped in GitHub Releases
- Source code under `src/`
- Release pipeline under `.github/workflows/`

**Out of scope** — report these upstream:

- `libghostty-vt` (VT parser / terminal engine): https://github.com/ghostty-org/ghostty/security
- `OpenConsole.exe` / `conpty.dll` (Microsoft ConPTY): https://github.com/microsoft/terminal/security

Bug reports that turn out to originate in an upstream component will be
closed with a pointer to the upstream tracker.
