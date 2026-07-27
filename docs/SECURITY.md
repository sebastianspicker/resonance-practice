# Security and privacy model

This document describes controls present in the source and obligations left to
an operator. The source-only alpha is not evidence of a secure production
deployment.

## Vulnerability reporting

Report vulnerabilities through
[GitHub private vulnerability reporting](https://github.com/sebastianspicker/resonance/security/advisories/new).
Do not open a public issue.

Use synthetic data and redacted logs. Do not include credentials, tokens,
signed URLs, private recordings, student data, or environment files.

## Protected assets

- Student audio and teaching-lesson video.
- Practice entries, markers, and teacher feedback.
- User identity and course membership.
- Access tokens, refresh tokens, OpenID Connect state, and application codes.
- Calendar subscription URLs.

## Trust boundaries

- iOS client to API. Production requires TLS.
- API to PostgreSQL.
- API to S3-compatible object storage.
- API to the configured OpenID Connect provider.
- iOS client to a user-provided iCalendar feed.

The repository provides loopback development services. Production network,
identity, database, storage, and key-management boundaries are supplied by the
operator.

## Authentication and authorization

- `AUTH_MODE=dev` enables unauthenticated development routes. The server
  defaults to `127.0.0.1`, rejects explicit non-loopback development hosts,
  and rejects non-loopback requests to `/dev/*`.
- Production authentication uses configured OpenID Connect through
  `/auth/login`. No live provider is validated by this repository. See
  [OIDC configuration](./SSO_BRIDGE.md).
- Access tokens are short-lived. Refresh tokens rotate, are stored as hashes,
  and use family revocation to contain replay.
- OpenID Connect state and internal application codes are single-use,
  short-lived hashes stored in PostgreSQL.
- Global student or teacher role does not grant course access. Route handlers
  enforce course membership, course role, and entry ownership.
- Teachers cannot list, fetch, or download student drafts.

## Entry and synchronization integrity

- Mutating v1 commands carry a client operation identifier and optimistic entry
  version.
- Durable receipts bind successful operation identifiers to their payload and
  user. Reusing an identifier with different work is rejected.
- Commands are admitted in bounded batches and run in request order.
- Conflicting versions return a conflict result instead of overwriting newer
  server state.
- Queue rows are bound to the local account owner. Synchronization requires the
  authenticated session, local-data owner, and queue owner to match.
- Account replacement cancels active synchronization and requires explicit
  local-data deletion.

## Media controls

- Teaching-lesson submission requires private-course-review consent and at
  least one uploaded video artifact.
- Camera overlays and markers are manual composition aids. The application does
  not implement face, person, pose, or teaching analysis.
- Upload sessions are restricted to the owning student and use staging-only
  signed PUT URLs.
- Completion verifies the expected object size and integrity metadata before
  publishing an immutable final key.
- Concurrent and repeated completion requests use a leased, idempotent claim
  protocol.
- Download sessions are limited to the student owner or a teacher in the same
  course.
- Signed URLs are short-lived, excluded from logs, and returned with
  `Cache-Control: no-store`.
- Expired staging objects and deleted-entry objects enter a durable deletion
  queue after active credential and completion windows have ended.
- Per-user artifact quotas and bounded failed-row retention limit abandoned
  metadata.

## Device data

- Local media and exports use `NSFileProtectionComplete` and are excluded from
  backups.
- Access and refresh tokens, the local-data owner, and calendar subscription
  values use device-only Keychain storage.
- Teaching-lesson video remains local until the student begins submission.
- Confirmed sign-out deletes SwiftData records, media, feedback, calendar
  state, exports, and queued work.
- Ambiguous existing data is preserved for recovery instead of being deleted
  automatically.

## API protections

- Fastify logs redact authorization headers, passwords, tokens, and
  authorization codes.
- JSON request bodies are limited to 1 MiB.
- Authentication endpoints are limited to 10 requests per minute. Other
  routes default to 100 requests per minute.
- CORS is disabled when no origins are configured and production startup
  requires at least one exact origin.
- Helmet applies API security headers. HSTS is enabled in production mode.
- Dependency operations used by startup, readiness, artifact completion, and
  object deletion use a validated bounded timeout.
- Errors use stable codes and omit stack traces from client responses.

## Privacy behavior

- User records contain an identifier, display name, and global role.
- The source does not enable analytics.
- Entry deletion removes relational content and keeps only the client entry
  identifier and deletion time as a replay-prevention tombstone.
- The source does not implement an operator-configurable course or user-content
  retention period.
- Logs must not contain media content, signed URLs, calendar URLs, names, or
  unnecessary identifiers.
- Capture markers remain inside the private course-review workflow.

## Operator obligations

A production operator must:

- terminate TLS for all external traffic;
- inject secrets at runtime and rotate them after suspected disclosure;
- configure explicit CORS origins;
- use a supported and patched PostgreSQL service and S3-compatible object
  store;
- configure encryption at rest, network access control, backups, restoration,
  retention, monitoring, and alerting;
- validate OpenID Connect callback, state, role, refresh, logout, and denied
  access behavior;
- define deletion and retention policy for user content, tombstones, logs, and
  backups;
- test recovery from database, object-storage, and identity-provider failure;
- review dependency audit and CodeQL results before deployment.

The MinIO image and credentials in `infra/docker-compose.yml` are restricted to
loopback development and CI. They are not a production storage configuration.

## Repository checks

```bash
./scripts/secret-scan.sh
./scripts/check-no-build-artifacts.sh
cd server
npm audit --audit-level=high --omit=dev
```

CI also runs CodeQL against `server/`. Environment-file contents are excluded
from the repository secret scan and require manual review.
