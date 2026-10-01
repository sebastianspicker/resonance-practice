# OIDC integration

Production authentication uses the OIDC authorization code flow. A SAML-only
institution needs an operator-managed SAML-to-OIDC bridge; this repository does
not provide one.

## Flow

```text
iOS app -> GET /auth/login -> OIDC authorization
OIDC callback -> one-time internal application code -> POST /auth/session
```

The server persists a short-lived login attempt and stores hashes of state,
nonce, PKCE verifier, and browser binding. The browser receives the attempt in a
signed, HttpOnly cookie. A callback must match and consume the attempt before
the server exchanges the provider response and redirects to the app callback.

The native app generates a separate PKCE verifier. It sends the matching
`app_code_challenge` to `/auth/login`, receives the internal application code at
`APP_AUTH_REDIRECT_URI`, then sends the `codeVerifier` to `/auth/session`. This
native-app proof is separate from the browser-to-IdP PKCE verifier used during
the provider code exchange. The `redirectUri` in the session request must
exactly equal `APP_AUTH_REDIRECT_URI`.

## Required production configuration

Set `AUTH_MODE=prod`, an explicit `HOST`, exact `CORS_ORIGINS`,
`OIDC_DISCOVERY_URL`, `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`, and
`OIDC_REDIRECT_URI`, alongside the PostgreSQL, JWT, and S3 settings. Use an exact
callback, HTTPS outside loopback validation, and an operator-managed secret
store.

`APP_AUTH_REDIRECT_URI` is the application callback and must match the client
configuration exactly. It is distinct from `OIDC_REDIRECT_URI`, the provider
callback. In production, use distinct random 32-byte base64 or base64url values
for `JWT_SECRET` and `JWT_REFRESH_SECRET`; placeholders are rejected.

## Identity mapping

Users resolve through an issuer-scoped `(issuer, subject)` pair stored in
`ExternalIdentity`, so matching subjects from different issuers stay distinct.
The migration is additive: it adds external identity records and OIDC
attempt-binding fields without replacing existing internal user IDs.

The configured role claim maps exactly to the configured teacher value; every
other value maps to student. Course membership still controls course access.

## Validation

Validate a real integration in a disposable TLS, PostgreSQL, and S3-compatible
environment with synthetic student and teacher accounts. Cover successful
sign-in, invalid or replayed attempts, refresh rotation, logout, role mapping,
and denied course access. A browser redirect alone does not prove client
callback handling or course authorization.
