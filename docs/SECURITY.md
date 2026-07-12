# Security & GDPR

## Reporting a Vulnerability

Please do not open public issues for security vulnerabilities.

Send a private report with details and reproduction steps via GitHub's private vulnerability reporting on this repository.

We will acknowledge receipt within 7 days and provide a remediation timeline.

## Project Status

This is a production-pilot work tree, not a production deployment. Source controls are described below; operator and external-service requirements remain unverified until deployed and tested in the target environment.

## Implemented Source Controls

- Token-based auth with refresh rotation
- Dev auth routes are disabled unless `AUTH_MODE=dev`
- Secret scanning: `./scripts/secret-scan.sh`
- Dependency-audit command in CI: `npm audit --audit-level=high`
- SAST in CI: CodeQL (`.github/workflows/codeql.yml`)

## Scope Notes

- The source supports configured OIDC behind the app-facing `/auth/login` entrypoint. Configure `OIDC_DISCOVERY_URL`, `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`, and `OIDC_REDIRECT_URI` to enable it; no live provider is proven by this repository. See [docs/SSO_BRIDGE.md](./SSO_BRIDGE.md).
- Environment variables are required for secrets and must not be committed.

## Threat Model (Production-Pilot Scope)

### Assets

- Student audio/video recordings and feedback.
- User identity and course membership.
- Access/refresh tokens.

### Intended Trust Boundaries

- iOS client <-> API server (TLS is a deployment requirement)
- API server <-> Postgres
- API server <-> S3-compatible storage
- External: configured OIDC provider and user-provided iCal feeds

### Threats & Mitigations

- IDOR on course/entry IDs: server enforces membership checks on every request.
- Artifact upload integrity: presign/confirm are restricted to the owning student of the artifact entry.
- Teaching-lesson consent: server blocks submission of `teaching_lesson` entries until consent metadata is present.
- Teaching-lesson video requirement: server rejects teaching-lesson submission unless at least one uploaded video artifact is present.
- Teaching-lesson camera guidance: overlays and contours are preview-only client aids; the app stores the raw video plus manual marker metadata, not automatic face/person/pose analysis.
- Token theft: short-lived access tokens, refresh rotation, token hashes stored server-side, no tokens in logs.
- Media exposure: upload URLs are owner-only; download URLs are restricted to the owner or a same-course teacher through entry ACLs. Both use short TTLs, download responses are `no-store`, signed URLs are never logged, object keys are unguessable UUIDs, and the server verifies uploads by HEAD.
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
- Account isolation: the app records the local-data owner and requires explicit local-profile deletion before another account can continue. Confirmed sign-out deletes SwiftData, media, calendar state, feedback, and queued work.
- Lesson markers: capture markers are student-authored metadata tied to the entry/video artifact and remain inside the private course-review workflow.

## Deployment Requirements

- Terminate TLS for all production traffic; no production deployment is supplied by this repository.
- CORS is fail-closed by default when `CORS_ORIGINS` is empty.
- Configure PostgreSQL and object storage encryption, backup, access control, and retention in the target environment.
- Environment variables for secrets; no secrets in repo.
