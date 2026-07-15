# Security & GDPR

## Reporting a Vulnerability

Please do not open public issues for security vulnerabilities.

Send a private report with details and reproduction steps through [GitHub private vulnerability reporting](https://github.com/sebastianspicker/resonance/security/advisories/new) for this repository.

We will acknowledge receipt within 7 days and provide a remediation timeline.

## Project Status

`v0.1.0-alpha.1` is a source-only public alpha, not a production deployment. Source controls are described below; operator, signing, and external-service requirements remain unverified until deployed and tested in the target environment.

## Implemented Source Controls

- Token-based auth with refresh rotation
- Dev auth routes are disabled unless `AUTH_MODE=dev`
- Secret scanning: `./scripts/secret-scan.sh`
- Dependency-audit command in CI: `npm audit --audit-level=high`
- SAST in CI: CodeQL (`.github/workflows/codeql.yml`)

## Scope Notes

- The source supports configured OIDC behind the app-facing `/auth/login` entrypoint. Configure `OIDC_DISCOVERY_URL`, `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`, and `OIDC_REDIRECT_URI` to enable it; no live provider is proven by this repository. See [docs/SSO_BRIDGE.md](./SSO_BRIDGE.md).
- Environment variables are required for secrets and must not be committed.

## Threat Model (Alpha Source and Production-Pilot Target)

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
- Artifact upload integrity: presign/confirm are restricted to the owning student of the artifact entry; the declared byte count is signed and verified exactly before the artifact becomes available.
- Teaching-lesson consent: server blocks submission of `teaching_lesson` entries until consent metadata is present.
- Teaching-lesson video requirement: server rejects teaching-lesson submission unless at least one uploaded video artifact is present.
- Teaching-lesson camera guidance: overlays and contours are preview-only client aids; the app stores the raw video plus manual marker metadata, not automatic face/person/pose analysis.
- Token theft: short-lived access tokens, refresh rotation, token hashes stored server-side, no tokens in logs.
- Media exposure: upload URLs are owner-only; download URLs are restricted to the owner or a same-course teacher through entry ACLs. Both use short TTLs, download responses are `no-store`, signed URLs are never logged, object keys include an unguessable attempt suffix, and the server verifies uploads by HEAD. Expired uploads and deleted-entry objects enter a durable deletion queue that retries transient storage failures. Database and object-storage operations used by startup, readiness, confirmation, and cleanup have a validated bounded dependency timeout.
- Offline device loss: iOS File Protection (`NSFileProtectionComplete`) for local media and exports; calendar subscription URLs are stored in Keychain instead of plain app defaults.
- CSRF/redirect abuse in SSO: ASWebAuthenticationSession with strict callback URL scheme; `redirectUri` is validated in production mode against the registered OIDC callback URI and `resonance://` app scheme. OIDC state and app auth codes are single-use, short-lived hashes in PostgreSQL so validation works across API replicas. Dev auth flow intentionally skips `redirectUri` validation (localhost only).
- **Dev auth:** Use `AUTH_MODE=dev` only on localhost. Dev routes (`/dev/*`) are restricted to loopback clients and must never be exposed in reachable environments.

## GDPR Controls

- Data minimization: store only `id`, `displayName`, and role. No analytics by default.
- Deletion: the server hard-deletes entry content and relational metadata, retaining only the client-generated ID and deletion time as a replay-prevention tombstone. Object keys enter a durable asynchronous deletion queue with bounded retries.
- Retention: suggested retention is 12 months after course end (configurable).
- Logging: no media content; PII minimized and token values are redacted.
- Refresh-token replay: rotations retain a server-side family identifier. Reuse commits revocation of that lineage before returning an error, containing a stolen-first rotation without invalidating unrelated device sessions.
- Consent: teaching-lesson entries require explicit private course-review consent metadata before submission.
- Local-first media: teaching-lesson video remains local until the student starts submission.
- Account isolation: the app records the local-data owner and requires explicit local-profile deletion before another account can continue. Confirmed sign-out deletes SwiftData, media, calendar state, feedback, and queued work.
- Lesson markers: capture markers are student-authored metadata tied to the entry/video artifact and remain inside the private course-review workflow.

## Deployment Requirements

- Terminate TLS for all production traffic; no production deployment is supplied by this repository.
- CORS is fail-closed by default when `CORS_ORIGINS` is empty.
- Configure PostgreSQL and object storage encryption, backup, access control, and retention in the target environment.
- Environment variables for secrets; no secrets in repo.
