# Security Policy

## Reporting a vulnerability

Please report suspected vulnerabilities privately to
`hola@xpetalab.dev`. Include the affected version, impact, reproduction steps,
and the smallest safe proof of concept. Do not include real API keys, tokens,
private keys, conversation content, or server backups.

Do not open a public issue until the report has been acknowledged and a safe
disclosure plan has been agreed. This project is maintained on a best-effort
basis and does not currently operate a paid bug-bounty program.

## Supported versions

Security fixes target the latest published release and the current default
development branch. Older releases may receive a backport when the impact and
available maintainer time justify it.

## Scope

Reports about Console are in scope. Vulnerabilities in Hermes Agent,
Flutter, Android, or another dependency should also be reported to that
project's security contact; a private heads-up here is welcome when Console is
directly affected.

The application's security architecture and data-handling rules are documented
in [docs/SECURITY_POLICY.md](docs/SECURITY_POLICY.md).
