# API contract

The API accepts JSON and uses bearer access tokens on authenticated routes.
Errors share a stable envelope that includes a request ID. `/health`, `/ready`,
and `/auth/*` are intentionally unversioned; resource reads and media operations
live under `/api/v1`.

## Authentication and status

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/health` | Process liveness. |
| `GET` | `/ready` | PostgreSQL and storage readiness. |
| `GET` | `/auth/login` | Stable development or OIDC login entry. |
| `GET` | `/auth/oidc/login` | Starts configured production OIDC. |
| `GET` | `/auth/oidc/callback` | OIDC callback. |
| `POST` | `/auth/session` | Exchanges a one-time application code for a session. |
| `POST` | `/auth/refresh` | Rotates a refresh token. |
| `GET` | `/auth/me` | Returns the authenticated user. |
| `POST` | `/auth/logout` | Revokes active refresh-token state. |

`/dev/*` routes are loopback-only development support, not an external
integration contract. Native production sign-in sends an `app_code_challenge`
to `GET /auth/login`. `POST /auth/session` then requires the one-time `code`,
the matching `codeVerifier`, and a `redirectUri` that exactly equals the
configured `APP_AUTH_REDIRECT_URI`. The native app's PKCE exchange is separate
from the browser-to-identity-provider PKCE flow.

## Versioned reads

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api/v1/courses` | Courses visible to the authenticated user. |
| `GET` | `/api/v1/courses/:courseId/entries` | Accessible entries for a course. |
| `GET` | `/api/v1/courses/:courseId/review-queue` | Teacher review queue for a course. |
| `GET` | `/api/v1/entries/:entryId` | An accessible entry. |
| `GET` | `/api/v1/entries/:entryId/feedback` | Feedback for an accessible entry. |

Course membership and entry visibility are evaluated server-side. A global role
never replaces course authorization, and teachers cannot read student drafts.

Entry lists, review queues, and feedback history all return
`{ "items": [...], "nextCursor": "..." }`, where `nextCursor` is `null` on the
last page. Pass `limit` (default 50, maximum 200) and the returned `cursor` to
load the next page. Feedback is ordered by ascending creation time and ID; entry
lists and review queues use descending practice date, creation time, and ID. A
cursor must belong to the same visible collection. An invalid or removed cursor
returns a validation error, so restart from the first page.

Review queue items include `captureMarkerCount` and artifact summaries but omit
`captureMarkers`; fetch entry detail for the complete marker array. Feedback uses
the page envelope in place of the previous unbounded array, so update the alpha
server and client together for this change.

## Mutations

The canonical resource-mutation contract is:

```text
POST /api/v1/sync/commands
```

The request body is `{ "commands": [...] }` with one to 25 commands. Each command
has an `operationId`, `entityId`, `kind`, `payload`, and, where needed, a
`baseVersion`. Supported kinds are `createEntry`, `updateEntry`,
`replaceCaptureMarkers`, `submitEntry`, `deleteEntry`, and `createFeedback`.

Each result reports the operation, entity, kind, and a status: `applied`,
`duplicate`, `conflict`, `rejected`, or `retryable`. Entry-changing results carry
`currentVersion` and the entry `resource`; a `conflict` for a stale
`baseVersion` carries the server's current version and entry so the client can
recover. `rejected` and `retryable` results carry an error `code` and
`message`. Do not add unversioned
resource-mutation routes; the command contract is what provides ordering,
idempotency, ownership, and optimistic-concurrency guarantees.

## Media sessions

| Method | Path | Purpose |
| --- | --- | --- |
| `POST` | `/api/v1/artifact-sessions` | Creates a scoped upload session. |
| `POST` | `/api/v1/artifact-sessions/:sessionId/complete` | Completes an upload session. |
| `POST` | `/api/v1/artifacts/:artifactId/download-session` | Requests a short-lived download URL. |

These operations require authentication and enforce media visibility through the
owning entry and course. Creation requires the requested type, size, and a
padded-base64 SHA-256 checksum. The response's `uploadUrl` must be used with
exactly the returned `requiredHeaders` (`Content-Type`, `Content-Length`,
`x-amz-checksum-sha256`); length and checksum are part of the signature, so the
storage service rejects a request that omits or alters them. Completion
verifies those properties and bounded ISO-BMFF M4A/MP4 brand and
audio/video-track evidence before publication, and returns exactly `artifact`
and `currentVersion`. Do not log the returned
download URL.

## Errors

HTTP errors use one envelope:
`{ "error": { "code", "message", "details", "requestId", "currentVersion"? } }`.
`details` exposes only `field`, `reason`, `expected`, and `actual`;
`currentVersion` appears on version conflicts. Every response carries an
`x-request-id` header. Inside `POST /api/v1/sync/commands`, client errors are
returned per command as `rejected` or `conflict` results with the same `code`
values, and the request itself still succeeds.

| Status | Codes |
| --- | --- |
| 400 | `VALIDATION_ERROR` (also 413 for oversized bodies and 415 for non-JSON bodies), `INVALID_ROLE` |
| 401 | `MISSING_AUTH`, `INVALID_TOKEN`, `INVALID_CODE`, `INVALID_REFRESH`, `REFRESH_REVOKED`, `REFRESH_MISMATCH`, `REFRESH_ALREADY_USED`, `USER_NOT_FOUND` |
| 403 | `COURSE_ACCESS_DENIED`, `ENTRY_ACCESS_DENIED`, `STUDENT_ONLY`, `TEACHER_ONLY`, `DEV_AUTH_LOCAL_ONLY` |
| 404 | `NOT_FOUND`, `ENTRY_NOT_FOUND`, `ARTIFACT_NOT_FOUND`, `USER_NOT_FOUND` (development login) |
| 409 | `VERSION_CONFLICT`, `ID_CONFLICT`, `OPERATION_REUSED`, `ENTRY_LOCKED`, `ENTRY_NOT_SUBMITTED`, `CONSENT_REQUIRED`, `ARTIFACTS_NOT_UPLOADED`, `UPLOAD_INVALID` |
| 410 | `ENTRY_DELETED` |
| 429 | `RATE_LIMITED` (request rate, sync admission, receipt and upload quotas) |
| 500 | `INTERNAL_ERROR` |
| 501 | `AUTH_NOT_CONFIGURED` |
| 503 | `STORAGE_UNAVAILABLE` |

`server/src/platform/http/errorCodes.ts` is the source of truth for the codes;
field-level validation limits live with each module's payload parser.
