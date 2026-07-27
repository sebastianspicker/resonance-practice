# OpenID Connect configuration

Production authentication uses OpenID Connect authorization code flow. A
SAML-only identity provider requires an operator-managed SAML-to-OIDC bridge.
The repository does not include or validate such a bridge.

## Authentication flow

```text
iOS app
  GET /auth/login
API
  redirect to /auth/oidc/login
Identity provider
  authenticate user and redirect to /auth/oidc/callback
API
  validate state, exchange the provider code, and map the user
  redirect to resonance://auth-callback with a one-time internal code
iOS app
  POST /auth/session with the internal code
API
  return access token, refresh token, and user
```

The iOS app uses `ASWebAuthenticationSession`. The API stores only SHA-256
hashes of OpenID Connect state values and internal application codes in
PostgreSQL. State values expire after 10 minutes. Internal codes are single-use
and expire after 5 minutes.

## Required configuration

Production startup requires:

| Variable | Requirement |
| --- | --- |
| `AUTH_MODE` | Set to `prod`. |
| `HOST` | Explicit listener host or address without a URL scheme. |
| `CORS_ORIGINS` | At least one exact allowed origin. |
| `OIDC_DISCOVERY_URL` | URL passed to `openid-client` discovery. |
| `OIDC_CLIENT_ID` | Confidential client identifier registered with the provider. |
| `OIDC_CLIENT_SECRET` | Client secret registered with the provider. |
| `OIDC_REDIRECT_URI` | Exact HTTPS callback URI registered with the provider. |

Optional claim mapping:

| Variable | Default | Behavior |
| --- | --- | --- |
| `OIDC_ROLE_CLAIM` | `role` | String claim inspected for the teacher value. |
| `OIDC_TEACHER_VALUE` | `teacher` | Exact value mapped to the teacher role. |

All other claim values map to the student role. Array-valued group claims and
multi-role policies are not supported by the current equality check.

The backend also requires `DATABASE_URL`, `JWT_SECRET`, the required `S3_*`
settings, and the remaining production values described in the
[README](../README.md#configuration).

Example shape:

```text
AUTH_MODE=prod
HOST=0.0.0.0
CORS_ORIGINS=https://portal.example.edu
OIDC_DISCOVERY_URL=https://identity.example.edu
OIDC_CLIENT_ID=resonance
OIDC_CLIENT_SECRET=<secret-from-provider>
OIDC_REDIRECT_URI=https://api.example.edu/auth/oidc/callback
OIDC_ROLE_CLAIM=role
OIDC_TEACHER_VALUE=teacher
```

Do not copy placeholder values into an operating environment.

## Provider registration

Register a confidential OpenID Connect client with:

- authorization code flow;
- redirect URI matching `OIDC_REDIRECT_URI` exactly;
- response type `code`;
- scopes `openid profile email`;
- a string claim suitable for student and teacher mapping.

If the role claim requires an additional scope, the current fixed scope list in
`server/src/config.ts` must be changed and tested. The configuration does not
currently provide an environment variable for extra scopes.

## User mapping

The backend derives the local user identifier from the provider's stable `sub`
claim:

```text
sso:<sub>
```

On each login, it updates the display name and global role. Display name lookup
uses the first nonempty string from `name`, `preferred_username`, `email`, and
`sub`.

The global role comes from exact string comparison between
`OIDC_ROLE_CLAIM` and `OIDC_TEACHER_VALUE`. Course membership still controls
course-specific actions. A global teacher role alone does not grant access to
a course.

## Validation procedure

No live provider is configured in the repository. Validate an integration in a
disposable environment:

1. provision PostgreSQL and the S3-compatible object store;
2. set all production configuration;
3. register the exact HTTPS callback URI;
4. start the compiled API behind TLS;
5. open `/auth/login` through the public API origin;
6. complete provider authentication;
7. confirm the app receives `resonance://auth-callback`;
8. exchange the internal code once through `POST /auth/session`;
9. verify student and teacher claim mappings with synthetic accounts;
10. verify refresh rotation, logout, expiry, invalid state, and denied course
    access.

Browser observation alone does not prove that the iOS callback, token
persistence, course authorization, or logout path works.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Server exits during startup | Confirm all four `OIDC_*` values, `HOST`, and `CORS_ORIGINS` are set in production. |
| `/auth/oidc/login` returns 501 | OIDC configuration is incomplete. In development mode the route also returns 501 when OIDC is omitted. |
| Callback returns `VALIDATION_ERROR` | State is missing, expired, already used, or changed. |
| Callback returns `INVALID_CODE` | Provider code exchange failed. Check provider logs, client credentials, issuer metadata, and exact redirect URI. |
| User maps to student | Confirm the configured claim exists as a string and exactly matches `OIDC_TEACHER_VALUE`. |
| Display name is `Unknown User` | The token contains no nonempty string for `name`, `preferred_username`, `email`, or `sub`; a missing `sub` is rejected earlier. |
| Login works on one API process only | Confirm all replicas use the same PostgreSQL database. State and internal codes are database-backed. |

## Security requirements

- Store the OpenID Connect client secret and JWT secrets in an
  operator-managed secret store.
- Use HTTPS for the provider callback and external API traffic.
- Keep provider redirect URIs exact and minimal.
- Do not log provider tokens, internal codes, application tokens, or callback
  URLs containing codes.
- Test role mapping with accounts that should and should not receive teacher
  access.
- Rotate client and JWT secrets after suspected disclosure.
- Configure PostgreSQL retention and backup procedures for authentication and
  application records.
