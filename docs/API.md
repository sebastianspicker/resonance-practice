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

Each result reports the operation, entity, kind, and a status such as `applied`,
`duplicate`, `conflict`, `rejected`, or `retryable`. Do not add unversioned
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
padded-base64 SHA-256 checksum, and the signed upload fixes content type, length,
and checksum. Completion verifies those properties and bounded ISO-BMFF M4A/MP4
brand and audio/video-track evidence before publication. Do not log the returned
download URL.
