# Security model

## Implemented boundaries

- Authenticated routes require bearer access tokens. When a refresh token is
  replayed, the affected token family is revoked.
- Development authentication is loopback-only. Production login uses the OIDC
  authorization code flow.
- OIDC attempts are short-lived and single-use, and the server retains hashes of
  state, nonce, PKCE verifier, and browser binding. `ExternalIdentity` maps
  issuer and subject together, so a subject is never assumed globally unique.
- Native app sign-in adds a second PKCE boundary: the login request carries an
  app code challenge, and the session exchange must present its matching
  verifier and the exact configured app callback URI.
- Production JWT access and refresh signing secrets are distinct random 32-byte
  base64 or base64url values. Startup rejects documented placeholders, repeated
  material, and invalid encoding.
- Course membership and entry ownership are enforced in server application code.
  A global teacher role does not grant access to student drafts.
- Resource changes use typed commands with operation IDs, receipts, owner
  binding, and optimistic versions.
- Artifact sessions issue scoped upload capabilities. Protected downloads are
  short-lived, authorized, and returned with `Cache-Control: no-store`. Upload
  signatures bind type, length, and padded-base64 SHA-256; completion rechecks
  them and permits only bounded ISO-BMFF M4A/MP4 brand and track evidence before
  publication.
- API logs redact credentials and token-like request fields. Fastify applies
  request limits, rate limits, security headers, and stable error responses.

## Client boundaries

The client persists local work bound to the authenticated local owner. Tokens
and local identity data use Keychain-backed storage. Feature UI must not bypass
the typed Core outbox or the authorization rules.

## Operator responsibilities

This repository does not provide production operations. An operator must supply
TLS, runtime secrets, CORS origins, patched PostgreSQL and storage, encryption,
network controls, backups, restoration tests, retention, logging, monitoring,
alerting, and live OIDC validation. The local Compose credentials and storage
configuration are development defaults, not production settings.

Report vulnerabilities through the [security policy](../SECURITY.md).

The development database reset is gated by development mode, a loopback
`resonance/public` target, and the exact
`RESONANCE_CONFIRM_DEV_DB_RESET=RESET_DEVELOPMENT_DATABASE` confirmation.
