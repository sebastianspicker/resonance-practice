# Contributing to Resonance

Thanks for taking a look. Resonance handles private practice records, so a few
rules matter more than usual: preserve offline work, course authorization,
account ownership, consent, and protected media. Never use real student records,
recordings, tokens, or environment files in development, tests, screenshots, or
issue reports.

Before you edit, read the [architecture](docs/ARCHITECTURE.md) and the live
module. Keep server transport in a module's `http/` directory and business
rules, authorization, DTOs, and transactions in its `application/` directory.
A module may only import the `application/` code of the modules it is allowed
to use (see the architecture document). Keep iOS
wiring in `App`, reusable services and transport in `Core`, workflow UI in
`Features`, and generic UI in `SharedUI`; `scripts/check-ios-layers.mjs`
rejects references against that direction.

Resource mutations belong in `POST /api/v1/sync/commands` only. Add a command
handler to the module that owns the resource and register its kind in sync's
dispatch; do not add resource-specific, unversioned mutation routes. Preserve
operation IDs, queue ownership, optimistic versions, and retry behavior.

Treat authentication, reset guards, and media upload integrity as public
security contracts. The app's PKCE verifier binds to its `app_code_challenge`;
keep it distinct from the browser-to-IdP PKCE flow. Media creation and
completion must retain the signed content type, length, padded-base64 SHA-256
checksum, and supported-container checks.

Run focused checks as you work, then finish with:

```bash
./scripts/verify-repository.sh
```

Useful focused checks:

```bash
cd server && npm run typecheck && npm run build && npm run quality && npm run format:check
./scripts/verify-ios.sh
node scripts/validate-public-docs.mjs
```

In a pull request, list every check you ran and every check you did not, with
the reason. Preserve unrelated work, and do not commit, push, or deploy without
authorization. Report vulnerabilities through [SECURITY.md](SECURITY.md), never
a public issue.

[Development](docs/DEVELOPMENT.md) covers prerequisites, the guarded test
database, demo data, and the full validation matrix. Component commands live in
the [server README](server/README.md) and [iOS README](ios/ResonanceApp/README.md).
