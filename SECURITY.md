# Security Policy

## Supported version

Security fixes currently target the latest source on `main` and the
`v0.1.0-alpha.1` source-only public alpha once it is published. No signed app,
hosted service, production deployment, or support SLA is provided.

## Reporting a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/sebastianspicker/resonance/security/advisories/new).
Do not open a public issue.

Include:

- the affected revision and component;
- the expected and observed security boundary;
- minimal reproduction steps;
- impact and preconditions;
- suggested remediation, if known.

Do not include real credentials, tokens, signed media URLs, student data,
private recordings, or unredacted environment files. Use synthetic data and
redacted logs.

## What to expect

The maintainer will acknowledge a complete report when practical, investigate
it privately, and coordinate disclosure after a fix or mitigation is available.
Because this is an early source alpha, response times are best-effort.

## Security model

The detailed threat model, privacy controls, authentication boundaries, media
handling, retention behavior, and known deployment gaps are documented in
[docs/SECURITY.md](docs/SECURITY.md).
