# Security & GDPR

## Reporting a Vulnerability

Please do not open public issues for security vulnerabilities.

Send a private report with details and reproduction steps via GitHub's private vulnerability reporting on this repository.

We will acknowledge receipt within 7 days and provide a remediation timeline.

## Supported Versions

This is an MVP prototype. Security fixes are tracked on the active release branch and then included in release snapshots.

## Security Controls (Current)

- Token-based auth with refresh rotation
- Dev auth routes are disabled unless `AUTH_MODE=dev`
- Secret scanning: `./scripts/secret-scan.sh`
- Dependency audit in CI: `npm audit --audit-level=high`
- SAST in CI: CodeQL (`.github/workflows/codeql.yml`)

## Scope Notes

- Production auth uses OIDC behind the app-facing `/auth/login` entrypoint. Configure `OIDC_DISCOVERY_URL`, `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`, and `OIDC_REDIRECT_URI` to enable. See [docs/SSO_BRIDGE.md](./SSO_BRIDGE.md).
- Environment variables are required for secrets and must not be committed.

## Threat Model (MVP)

### Assets

- Student audio/video recordings and feedback.
- User identity and course membership.
- Access/refresh tokens.

### Trust Boundaries

- iOS client <-> API server (TLS)
- API server <-> Postgres
- API server <-> S3-compatible storage
- External: ILIAS deep links, ASIMUT iCal feeds

### Threats & Mitigations

- IDOR on course/entry IDs: server enforces membership checks on every request.
- Artifact upload integrity: presign/confirm are restricted to the owning student of the artifact entry.
- Teaching-lesson consent: server blocks submission of `teaching_lesson` entries until consent metadata is present.
- Teaching-lesson video requirement: server rejects teaching-lesson submission unless at least one uploaded video artifact is present.
- Teaching-lesson camera guidance: overlays and contours are preview-only client aids; the app stores the raw video plus manual marker metadata, not automatic face/person/pose analysis.
- Token theft: short-lived access tokens, refresh rotation, token hashes stored server-side, no tokens in logs.
- Media exposure: pre-signed URLs limited to short TTL; object keys are unguessable UUIDs; server verifies upload by HEAD.
- Offline device loss: iOS File Protection (`NSFileProtectionComplete`) for local media and exports; calendar subscription URLs are stored in Keychain instead of plain app defaults.
- CSRF/redirect abuse in SSO: ASWebAuthenticationSession with strict callback URL scheme; `redirectUri` is validated in production mode against the registered OIDC callback URI and `resonance://` app scheme. Dev auth flow intentionally skips `redirectUri` validation (localhost only).
- **Dev auth:** Use `AUTH_MODE=dev` only on localhost. Dev routes (`/dev/*`) are restricted to loopback clients and must never be exposed in reachable environments.

## GDPR Controls

- Data minimization: store only `id`, `displayName`, and role. No analytics by default.
- Deletion: entries can be deleted; server deletes metadata and storage object.
- Retention: suggested retention is 12 months after course end (configurable).
- Logging: no media content; PII minimized and token values are redacted.
- Consent: teaching-lesson entries require explicit private course-review consent metadata before submission.
- Local-first media: teaching-lesson video remains local until the student starts submission.
- Lesson markers: capture markers are student-authored metadata tied to the entry/video artifact and remain inside the private course-review workflow.

## Secure Defaults

- TLS enforced in production.
- CORS is fail-closed by default when `CORS_ORIGINS` is empty.
- Postgres and S3 encrypted at rest (documented for ops).
- Environment variables for secrets; no secrets in repo.
