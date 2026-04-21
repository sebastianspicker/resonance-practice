# Production SSO Bridge — Deployment Guide

This document explains how to wire up the Resonance backend to your university's Single Sign-On (SSO) system for production use.

Resonance uses **OpenID Connect (OIDC)** for production authentication. Most modern Shibboleth deployments support OIDC via a proxy (e.g. [SATOSA](https://github.com/IdentityPython/SATOSA)) or natively. If your university only exposes SAML, you will need a SAML-to-OIDC bridge.

---

## Overview

The production auth flow:

```
iOS app (ASWebAuthenticationSession)
  ↓  opens https://<api>/auth/oidc/login
API server
  ↓  redirects to university IdP (OIDC authorization endpoint)
University IdP
  ↓  user authenticates (Shibboleth / LDAP / etc.)
  ↓  redirects back to https://<api>/auth/oidc/callback?code=...&state=...
API server
  ↓  exchanges code for ID token, validates claims
  ↓  creates or updates the Resonance user in the database
  ↓  issues a short-lived internal auth code
  ↓  redirects to resonance://auth-callback?code=<internal-code>
iOS app (ASWebAuthenticationSession captures the resonance:// redirect)
  ↓  POST /auth/session { code: <internal-code> }
API server
  ↓  issues JWT access token + refresh token
```

After token issuance the flow is identical to development mode.

---

## Environment Variables

Set the following in your production environment (do **not** put these in `server/.env.example` with real values):

| Variable | Required | Description |
|----------|----------|-------------|
| `AUTH_MODE` | ✅ | Must be `prod` |
| `OIDC_DISCOVERY_URL` | ✅ | OIDC issuer URL. The server will fetch `<url>/.well-known/openid-configuration` on first use. |
| `OIDC_CLIENT_ID` | ✅ | OAuth2 client ID registered with your IdP. |
| `OIDC_CLIENT_SECRET` | ✅ | OAuth2 client secret. Treat as a high-value secret. |
| `OIDC_REDIRECT_URI` | ✅ | Must match the redirect URI registered in the IdP exactly. Usually `https://<api-domain>/auth/oidc/callback`. |
| `OIDC_ROLE_CLAIM` | ☑️ optional | Name of the OIDC claim that carries the user's role. Default: `role`. |
| `OIDC_TEACHER_VALUE` | ☑️ optional | Value of `OIDC_ROLE_CLAIM` that means "teacher". Default: `teacher`. All other values are mapped to `student`. |

All other required variables (`JWT_SECRET`, `DATABASE_URL`, `S3_*`, `CORS_ORIGINS`) must also be set. See `server/.env.example`.

### Example

```bash
AUTH_MODE=prod
CORS_ORIGINS=https://api.university.de

OIDC_DISCOVERY_URL=https://sso.university.de/.well-known/openid-configuration
OIDC_CLIENT_ID=resonance-prod
OIDC_CLIENT_SECRET=<your-client-secret>
OIDC_REDIRECT_URI=https://api.university.de/auth/oidc/callback

# Role mapping (adjust to match your IdP's claim structure)
OIDC_ROLE_CLAIM=eduPersonAffiliation
OIDC_TEACHER_VALUE=staff
```

---

## IdP Registration

Register a new OAuth2/OIDC client in your university's IdP console with:

- **Client type:** Confidential
- **Allowed grant types:** Authorization Code
- **Redirect URI:** `https://<api-domain>/auth/oidc/callback`
- **Requested scopes:** `openid profile email` (plus any custom scopes for role claims)
- **Response types:** `code`

---

## Role Mapping

Resonance recognises two roles: `student` and `teacher`.

By default the server reads the `role` claim from the OIDC ID token. If its value matches `OIDC_TEACHER_VALUE` (default: `teacher`), the user is assigned the `teacher` role; otherwise `student`.

### Common Shibboleth / university scenarios

| IdP claim | Example value | Recommended config |
|-----------|--------------|-------------------|
| `role` | `teacher` | Default (no config needed) |
| `eduPersonAffiliation` | `staff` | `OIDC_ROLE_CLAIM=eduPersonAffiliation`, `OIDC_TEACHER_VALUE=staff` |
| `groups` (array) | `["lecturers"]` | Not directly supported by the current claim matcher (string comparison). See *Custom role logic* below. |

### Custom role logic

If your IdP encodes roles as a JSON array or requires more complex logic, edit `server/src/oidc.ts` → `roleFromClaims()`. The function receives the full set of OIDC claims as a plain object and must return `'student' | 'teacher'`.

---

## User Identity

Each user is stored in the database with an `id` of the form `sso:<oidc-sub-claim>`. The `sub` claim is stable per user per IdP and is used for upsert on every login — display name and role are refreshed on each login from current IdP claims.

---

## CORS

Set `CORS_ORIGINS` to your app's origin. For an iOS-only app with no web frontend, you may leave this empty if the server is never accessed from a browser; however the production check enforces at least one origin is set. If needed, add `resonance://` as an allowed origin pattern or remove the CORS check for the app scheme.

---

## Testing the OIDC Integration

1. Start the server with all `OIDC_*` variables set and `AUTH_MODE=prod`.
2. Open `https://<api>/auth/oidc/login` in a browser — you should be redirected to the university IdP.
3. After authentication the browser will attempt to redirect to `resonance://auth-callback?code=...`. The browser cannot open this URL (it's an app scheme), but the redirect appearing in the browser's address bar or network log confirms the flow works.
4. From iOS, use `ASWebAuthenticationSession` to open `/auth/oidc/login`. The session will capture the `resonance://` redirect and close automatically.

---

## Troubleshooting

| Symptom | Likely cause |
|---------|-------------|
| Server refuses to start with OIDC error | One or more `OIDC_*` env vars missing while `AUTH_MODE=prod` |
| `/auth/oidc/login` returns 501 | `AUTH_MODE` is not `prod` or OIDC vars are not set |
| `/auth/oidc/callback` returns `INVALID_CODE` | OIDC token exchange failed; check IdP logs and redirect URI exact match |
| `/auth/oidc/callback` returns `VALIDATION_ERROR` (state) | State expired (>10 min) or state parameter was modified in transit |
| User always gets `student` role | `OIDC_ROLE_CLAIM` / `OIDC_TEACHER_VALUE` do not match the claim the IdP sends; inspect the ID token claims with a JWT decoder |
| Display name is "Unknown User" | ID token is missing `name`, `preferred_username`, `email`, and `sub` claims |

---

## Security Notes

- The OIDC `state` parameter is validated on every callback to prevent CSRF attacks.
- The internal auth code issued after successful OIDC authentication is single-use and expires after 5 minutes.
- `redirectUri` in `POST /auth/session` is validated against the registered OIDC callback URI in production mode.
- Dev auth endpoints (`/dev/*`) return 404 in `AUTH_MODE=prod` — they are not accessible.
- Keep `OIDC_CLIENT_SECRET` and `JWT_SECRET` in a secrets manager (e.g. AWS Secrets Manager, HashiCorp Vault) and inject them as environment variables at runtime.
