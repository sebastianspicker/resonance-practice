# API Reference

This document describes the routes implemented in the current source tree. It is not evidence of a deployed or externally validated service.

Base URL: `http://localhost:4000`

The iOS alpha client uses the `/api/v1` routes below for synchronization, reads, and artifact transfers. The unversioned route descriptions retained later in this document are compatibility surfaces; new clients must use v1.

All authenticated endpoints require an `Authorization: Bearer <accessToken>` header.

## Response Headers

Every response includes:

- `x-request-id`: a unique identifier for the request, useful for tracing and debugging. Clients should log this value and include it in bug reports to help correlate issues with server-side logs.

## Service Probes

- `GET /health` is a process-liveness probe and returns `{ "status": "ok" }` without querying dependencies.
- `GET /ready` checks PostgreSQL and the configured object-storage bucket within the validated dependency deadline. It returns `{ "status": "ready" }` with `200`, or `{ "status": "unavailable" }` with `503`.

## Service Probes

- `GET /health` is a process-liveness probe and returns `{ "status": "ok" }` without querying dependencies.
- `GET /ready` checks PostgreSQL and the configured object-storage bucket within the validated dependency deadline. It returns `{ "status": "ready" }` with `200`, or `{ "status": "unavailable" }` with `503`.

## Status Codes

In addition to the error codes listed below, the API uses:

- `201 Created`: returned by `POST` endpoints that create a resource (for example, `POST /courses/:courseId/entries` and `POST /auth/session`).
- `204 No Content`: returned by `DELETE` endpoints on success with an empty body.
- `200 OK`: all other successful responses.

## Version 1 sync and artifacts

### POST /api/v1/sync/commands

Applies one to 25 commands in request order. A batch may contain independent entities, but commands affecting the same entity are processed FIFO. Each command has a client-generated `operationId`; retries with the same ID and payload return the stored outcome instead of applying the mutation again.

```json
{
  "commands": [
    {
      "operationId": "operation-id",
      "entityId": "entry-id",
      "kind": "updateEntry",
      "baseVersion": 3,
      "payload": {
        "courseId": "course-id",
        "goalText": "Work on arpeggios"
      }
    }
  ]
}
```

Supported `kind` values are `createEntry`, `updateEntry`, `replaceCaptureMarkers`, `submitEntry`, `deleteEntry`, and `createFeedback`. `createEntry` does not carry `baseVersion`; every other kind requires a positive integer `baseVersion`.

Each result has this shape:

```json
{
  "operationId": "operation-id",
  "entityId": "entry-id",
  "kind": "updateEntry",
  "status": "applied|duplicate|conflict|rejected|retryable",
  "code": "optional-machine-code",
  "message": "optional-message",
  "currentVersion": 4,
  "resource": { "optional": "entry representation" }
}
```

`applied` and `duplicate` are successful outcomes. `conflict` means the supplied entry version is stale; clients must reconcile with `currentVersion` rather than overwriting newer server data. `rejected` is a terminal business or validation failure, while `retryable` means the client may retry using the same operation ID. Reusing a command operation ID with a different payload returns an HTTP `200` result with `status: "rejected"` and `code: "OPERATION_REUSED"`.

Only successful mutations retain receipts. Receipts bind a payload hash and
minimal authorization context for seven days; replay rechecks current course
membership and omits resources that have since been deleted. Admission is
limited to 12 requests and 100 commands per authenticated user per minute, with
at most 500 unexpired receipts per user. Quota exhaustion fails closed with
`429 RATE_LIMITED` before the mutation commits.

### POST /api/v1/artifact-sessions

Allocates (or retrieves) an idempotent artifact-upload session. Only the student owner of a draft entry may allocate one.

```json
{
  "operationId": "operation-id",
  "entryId": "entry-id",
  "artifactId": "artifact-id",
  "type": "audio",
  "durationSeconds": 120,
  "sizeBytes": 1048576,
  "baseVersion": 4
}
```

The response includes `sessionId`, the artifact representation, a signed
staging `uploadUrl`, `requiredHeaders`, `expiresInSeconds`, the entry's
`currentVersion`, and `completed`. Clients must send the returned headers
unchanged. The allocation increments the entry version; subsequent dependent
commands must use `currentVersion`.

If a retry finds that the session already completed, the response contains
`completed: true`, `uploadUrl: null`, and `requiredHeaders: null`; it never
issues another PUT credential. An active-session retry is signed only for the
exact remaining session lifetime reported in `expiresInSeconds`; a session with
too little lifetime is rotated to a new staging key before signing.

### POST /api/v1/artifact-sessions/:sessionId/complete

Completes an upload session through a durable claim/CAS protocol. The server
HEAD-verifies the staging object's exact size, pins the copy to the observed
ETag, copies it to a claim-token-specific final key, and publishes only that
final key. A concurrent completion request receives `409 UPLOAD_INVALID` with
an in-progress retry message and does not issue storage requests. The response
is:

```json
{ "artifact": { "id": "artifact-id", "uploadState": "uploaded" }, "currentVersion": 5 }
```

Completion is idempotent. Staging cleanup is delayed until the signed PUT has
expired and any bounded completion claim has ended, plus grace, so a late
client write or copy cannot recreate published or untracked evidence. Missing
or mismatched objects, missing integrity validators, and source-precondition
failures return `409 UPLOAD_INVALID`; unavailable storage returns
`503 STORAGE_UNAVAILABLE`.

### v1 read inventory

- `GET /api/v1/me`
- `GET /api/v1/courses`
- `GET /api/v1/courses/:courseId/entries?cursor=&limit=&status=`
- `GET /api/v1/courses/:courseId/review-queue?cursor=&limit=`
- `GET /api/v1/entries/:entryId`
- `GET /api/v1/entries/:entryId/feedback`
- `POST /api/v1/artifacts/:artifactId/download-session`

Entry and review-queue pages use `{ "items": [], "nextCursor": "string-or-null" }`, default to 50 items, accept at most 200 items, and use deterministic `practiceDate DESC`, `createdAt DESC`, `id DESC` ordering. Download-session responses contain a short-lived `downloadUrl` and set `Cache-Control: no-store`.

Students can read only their own entries. Teachers can read only `submitted`
or `reviewed` entries in their courses; draft list filters, details, feedback,
and artifact downloads are denied.

## Auth

### POST /auth/session

Exchange authorization code for tokens.

Rate limit: 10 requests per minute.

Request:
```json
{ "code": "string", "redirectUri": "string" }
```

- `code` (required): authorization code, max 2048 characters.
- `redirectUri` (optional): validated in production mode against the registered OIDC callback URI (`OIDC_REDIRECT_URI`) or the app custom scheme (`resonance://auth-callback`). Ignored in dev mode.

Response:
```json
{
  "accessToken": "jwt",
  "refreshToken": "jwt",
  "user": { "id": "...", "displayName": "...", "globalRole": "student|teacher" }
}
```

### POST /auth/refresh

Rotate refresh token. Works in both dev and production modes.

Rate limit: 10 requests per minute.

Request:
```json
{ "refreshToken": "jwt" }
```

Response:
```json
{ "accessToken": "jwt", "refreshToken": "jwt" }
```

### GET /auth/me

Return the authenticated user's profile.

Authorization: requires valid access token.

Response:
```json
{ "id": "...", "displayName": "...", "globalRole": "student|teacher" }
```

### POST /auth/logout

Revoke a user's refresh-token family.

One of the following is required:

- a valid access token; or
- a JSON body containing the refresh token, which allows logout after the access
  token has expired.

Refresh-token logout is deliberately idempotent and does not reveal whether the
token was recognized.

Request body for refresh-token logout:

```json
{ "refreshToken": "jwt" }
```

Response:
```json
{ "success": true }
```

### GET /auth/login

App-facing login entrypoint.

- In `AUTH_MODE=dev`, redirects to `/dev/login` and keeps the localhost-only dev auth guard.
- In `AUTH_MODE=prod`, redirects to `/auth/oidc/login`.

Response: `302 Redirect`.

### GET /auth/oidc/login

Initiates the OIDC authorization flow and redirects the client to the configured university IdP. `/auth/login` selects this route only in production mode, but the route itself is registered in both modes.

Production startup requires `OIDC_DISCOVERY_URL`, `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`, and `OIDC_REDIRECT_URI`. Development mode may omit them; a direct call then returns `501 AUTH_NOT_CONFIGURED`.

Response: `302 Redirect` → university IdP authorization URL.

### GET /auth/oidc/callback

OIDC callback endpoint. Exchanges the authorization code for an ID token, upserts the user, issues an internal single-use auth code, and redirects to the iOS app custom URL scheme.

Response: `302 Redirect` → `resonance://auth-callback?code=<internal-code>`

The internal code must be exchanged via `POST /auth/session` within 5 minutes.

See [docs/SSO_BRIDGE.md](./SSO_BRIDGE.md) for the full deployment guide.

### Production Auth Flow

1. iOS opens `/auth/login` via `ASWebAuthenticationSession`.
2. Server redirects to university IdP.
3. User authenticates; IdP redirects to `/auth/oidc/callback`.
4. Server validates, upserts user, issues internal code, redirects to `resonance://auth-callback?code=...`.
5. `ASWebAuthenticationSession` captures the `resonance://` redirect.
6. iOS calls `POST /auth/session { code }` to receive JWT tokens.

### Dev Auth Routes (dev only)

All `/dev/*` routes are localhost-only. Non-loopback requests receive a `403` with error code `DEV_AUTH_LOCAL_ONLY`.

#### GET /dev/login

HTML login page (ASWebAuthenticationSession) that presents persona selection links and redirects to `resonance://auth-callback`.

#### GET /dev/authorize

Authorize as a dev persona and redirect with an authorization code.

Query parameters:

- `role` (required): `student` or `teacher`.

Redirects to `resonance://auth-callback?code=...`.

#### POST /dev/issue

Issue a dev authorization code programmatically (useful for tests/scripts).

Request:
```json
{ "role": "student|teacher", "userId": "string (optional)" }
```

- `role` (optional, default `"student"`): create or update a persona with this role.
- `userId` (optional): issue a code for an existing user by ID. If provided, `role` is ignored.

Response:
```json
{ "code": "string" }
```

## Courses

### GET /courses

Returns courses for the current user.

Response (array):
```json
[
  { "id": "...", "title": "...", "roleInCourse": "student|teacher" }
]
```

### GET /courses/:courseId

Returns course details.

## Practice Entries

### GET /courses/:courseId/entries

Returns entries visible to the user, including nested `artifacts`.

Optional query parameters:

- `status`: filter by entry status: `draft`, `submitted`, or `reviewed`. Invalid values return `400 VALIDATION_ERROR`.
  - Students: without a filter, all of the student's entries are returned. With a filter, only entries matching that status are returned.
  - Teachers: without a filter, only `submitted` entries are returned. Teachers may request `submitted` or `reviewed`; requesting `draft` returns `403 ENTRY_ACCESS_DENIED`.
- `limit`: max number of items per page (default: 50, max: 200).
- `cursor`: entry ID of the last item on the previous page. Omit for the first page.

Response shape:
```json
{
  "items": [ /* entry objects with nested artifacts */ ],
  "nextCursor": "entry-id-or-null"
}
```

Sort order: `practiceDate DESC`, `createdAt DESC`, `id DESC`.

### GET /entries/:entryId

Fetch a single entry by ID, including nested `artifacts` and `captureMarkers`.

Authorization:

- Students can only fetch their own entries.
- Teachers can fetch only submitted or reviewed entries in courses they belong to. Draft details are denied.

Returns `404 ENTRY_NOT_FOUND` if the entry does not exist or was deleted, and `403 ENTRY_ACCESS_DENIED` if the user is not allowed to see it. A tombstoned client ID is rejected when stale work attempts to recreate a deleted entry.

### POST /courses/:courseId/entries

Create an entry. Only students can create entries.

Request:
```json
{
  "id": "client-generated-id",
  "kind": "practice",
  "practiceDate": "2025-03-15",
  "goalText": "Work on arpeggios",
  "durationSeconds": 1800,
  "tags": ["technique", "scales"],
  "notes": "Optional free-text notes"
}
```

Teaching-lesson entry:
```json
{
  "id": "client-generated-id",
  "kind": "teaching_lesson",
  "practiceDate": "2025-03-15T10:00:00Z",
  "goalText": "Reflect on rhythm-teaching sequence",
  "tags": ["lehramt", "rhythmus"],
  "notes": "Focus on modelling, transitions, and participation.",
  "consentConfirmed": true,
  "consentScope": "private_course_review",
  "captureProfile": "teacher_learner"
}
```

- `id` (required): client-generated ID, 1-128 alphanumeric, hyphen, or underscore characters. An exact repeat returns the existing entry with `200`; reusing the ID with different create data returns `409 ID_CONFLICT`.
- `kind` (optional, default `"practice"`): `"practice"` or `"teaching_lesson"`.
- `practiceDate` (required): ISO 8601 date (`YYYY-MM-DD`) or datetime with timezone (`YYYY-MM-DDTHH:mm:ssZ`).
- `goalText` (required): string, max 10000 characters.
- `durationSeconds` (optional): number, 0-28800 (8 hours).
- `tags` (optional, default `[]`): string array, max 30 tags, each trimmed tag must be non-empty and max 100 characters.
- `notes` (optional): string or null.
- `consentConfirmed` (optional): boolean. Only valid for `teaching_lesson`.
- `consentScope` (optional): currently `"private_course_review"`. Required when `consentConfirmed` is `true`.
- `captureProfile` (optional): only valid for `teaching_lesson`. One of `room_overview`, `teacher_learner`, `instrument_closeup`, `ensemble_group`, `group_work`.

New entries are created with status `draft`.

### PATCH /entries/:entryId

Update entry fields. Only the owning student can edit.

Updatable fields: `goalText`, `practiceDate`, `durationSeconds`, `tags`, `notes`, `kind`, `consentConfirmed`, `consentScope`, `captureProfile`. Only fields present in the request body are updated. Send `null` for `durationSeconds`, `notes`, `consentScope`, or `captureProfile` to clear those fields.

Restriction: if the entry status is not `draft`, updating any of these fields returns `409 ENTRY_LOCKED`.

### DELETE /entries/:entryId

Hard-delete the entry content, relationships, artifacts, markers, and feedback. A minimal tombstone containing only the client-generated entry ID and deletion time prevents stale offline work from reusing the identifier. Object-storage keys are committed to a durable deletion queue in the same transaction and removed asynchronously with retry. Only the owning student can delete.

Response: `204 No Content` (empty body).

### POST /entries/:entryId/submit

Submit an entry for review. Only the owning student can submit.

Preconditions:

- Entry status must be `draft` (otherwise `409 ENTRY_LOCKED`).
- Teaching-lesson entries must have `consentConfirmedAt` and `consentScope` (otherwise `409 CONSENT_REQUIRED`).
- Entry must have at least one artifact, and all artifacts must be in `uploaded` state (otherwise `409 ARTIFACTS_NOT_UPLOADED`).
- Teaching-lesson entries must include at least one uploaded `video` artifact; audio-only evidence is rejected with `409 ARTIFACTS_NOT_UPLOADED`.

Entry lifecycle:

- `draft` -> `submitted` -> `reviewed`
- Editing and submitting are restricted to `draft` entries only.

## Artifacts

### Retired mutation routes

The following compatibility mutations return `410 UPLOAD_INVALID`:

- `POST /entries/:entryId/artifacts`
- `POST /artifacts/:artifactId/presign`
- `POST /artifacts/:artifactId/confirm`

They wrote directly to a served object key and cannot satisfy the immutable
staging/finalization boundary. Clients must use
`POST /api/v1/artifact-sessions` and
`POST /api/v1/artifact-sessions/:sessionId/complete`.

### GET /artifacts/:artifactId/download

Returns a short-lived URL for private playback. The student owner is
authorized; a teacher must belong to the same course and the parent entry must
be submitted or reviewed. Draft media is denied to teachers. The artifact must
be uploaded, nondeleted, and have a storage key.

Response:
```json
{
  "downloadUrl": "https://object-storage.example/signed-request",
  "expiresInSeconds": 900
}
```

The response sets `Cache-Control: no-store`. Signed URLs must not be logged.
Pending or failed artifacts return `409 UPLOAD_INVALID`; unrelated users receive
the same entry authorization errors as `GET /entries/:entryId`.

### PUT /entries/:entryId/capture-markers

Idempotently replace the manual lesson-contour marker set for a teaching-lesson video. Only the owning student can write markers. Draft and submitted teaching-lesson entries accept marker sync; reviewed entries return `409 ENTRY_LOCKED`.

Request:
```json
{
  "markers": [
    {
      "id": "client-generated-id",
      "artifactId": "video-artifact-id",
      "timeSeconds": 42,
      "kind": "moment_student_response",
      "note": "Student echoes the rhythm."
    }
  ]
}
```

- `id` (required): client-generated marker ID, 1-128 alphanumeric, hyphen, or underscore characters.
- `artifactId` (required): video artifact ID belonging to the same entry. Audio artifacts and artifacts from other entries return `404 ARTIFACT_NOT_FOUND`.
- `timeSeconds` (required): integer, 0-28800.
- `kind` (required): one of `phase_setup`, `phase_modeling`, `phase_guided_practice`, `phase_student_work`, `phase_feedback`, `phase_reflection`, `moment_question`, `moment_musical_model`, `moment_student_response`, `moment_transition`, `privacy_note`.
- `note` (optional): free text, max 1000 characters.

Markers omitted from the `markers` array are deleted for that entry. Send an empty array to clear all lesson-contour markers.

Response:
```json
[
  {
    "id": "client-generated-id",
    "entryId": "entry-id",
    "artifactId": "video-artifact-id",
    "studentId": "student-id",
    "timeSeconds": 42,
    "kind": "moment_student_response",
    "note": "Student echoes the rhythm.",
    "createdAt": "2026-04-29T12:00:00.000Z"
  }
]
```

## Feedback

### GET /courses/:courseId/review-queue

Teacher-only list of submitted entries with cursor-based pagination.

The response is an object containing `items` and `nextCursor`.

Optional query parameters:

- `limit`: number of items per page (default 20, max 100). Values below 1 return `400 VALIDATION_ERROR`.
- `cursor`: entry ID from a previous `nextCursor` value. The server returns items ordered after this entry. Invalid cursor IDs return `400 VALIDATION_ERROR`.

Response:
```json
{
  "items": [
    {
      "id": "...",
      "courseId": "...",
      "studentId": "...",
      "studentName": "...",
      "kind": "practice",
      "practiceDate": "...",
      "goalText": "...",
      "notes": "...",
      "tags": ["..."],
      "durationSeconds": 1800,
      "status": "submitted",
      "consentConfirmedAt": null,
      "consentScope": null,
      "captureProfile": null,
      "captureMarkerCount": 0,
      "artifacts": [...]
    }
  ],
  "nextCursor": "entry-id-of-last-item | null"
}
```

Ordering:

- Deterministic order by `practiceDate desc`, `createdAt desc`, `id desc`.

Pagination:

- Cursor-based using entry ID. To fetch the next page, pass the `nextCursor` value from the previous response as the `cursor` query parameter.
- When `nextCursor` is `null`, there are no more results.

### POST /feedback

Create feedback on an entry or artifact. Only course teachers can leave feedback.

When `id` is supplied, retries are idempotent only if the existing feedback has
the same teacher, target, status, comments, and marker set. Reusing an `id` with
different content returns `409 ID_CONFLICT`.

Request:
```json
{
  "id": "optional-client-generated-id",
  "targetType": "entry|artifact",
  "targetId": "...",
  "status": "ok|needs_revision|next_goal",
  "commentsText": "Great progress on your scales.",
  "markers": [
    { "timeSeconds": 45, "text": "Intonation slipped here" }
  ]
}
```

- `id` (optional): client-generated ID, 1-128 alphanumeric, hyphen, or underscore characters.
- `targetType` (required): `"entry"` or `"artifact"`.
- `targetId` (required): ID of the entry or artifact.
- `status` (required): `"ok"`, `"needs_revision"`, or `"next_goal"`.
- `commentsText` (required): trimmed non-empty string, max 10000 characters.
- `markers` (optional, default `[]`): array of time-stamped annotations, max 50 markers.
  - `timeSeconds` (required): integer, 0-28800.
  - `text` (required): string, max 1000 characters.

Preconditions:

- The target entry (or the artifact's parent entry) must be in `submitted` or `reviewed` status (not `draft`; otherwise `409 ENTRY_NOT_SUBMITTED`).
- Deleted entries return `410 ENTRY_DELETED`.

Side effect:

- When feedback is created, the parent entry status is set to `reviewed`.

### GET /entries/:entryId/feedback

Fetch feedback for an entry.

Response (array):
```json
[
  {
    "id": "...",
    "targetType": "entry",
    "targetId": "...",
    "teacherId": "...",
    "teacherName": "...",
    "createdAt": "...",
    "status": "ok|needs_revision|next_goal",
    "commentsText": "...",
    "markers": [
      { "id": "...", "timeSeconds": 45, "text": "..." }
    ]
  }
]
```

## Errors

All errors use:
```json
{ "error": { "code": "STRING_CODE", "message": "Human readable message", "details": {} } }
```

### Error Codes

| Code | Description |
|------|-------------|
| `MISSING_AUTH` | No authorization header provided |
| `INVALID_TOKEN` | Access token is invalid or expired |
| `INVALID_REFRESH` | Refresh token is invalid or expired |
| `REFRESH_REVOKED` | Refresh token has been revoked |
| `REFRESH_MISMATCH` | Refresh token does not match stored hash |
| `REFRESH_ALREADY_USED` | Refresh token was already consumed; its active rotation lineage is revoked |
| `INVALID_CODE` | Authorization code is invalid or expired |
| `USER_NOT_FOUND` | User does not exist |
| `DEV_AUTH_LOCAL_ONLY` | Dev auth routes only available from localhost |
| `AUTH_NOT_CONFIGURED` | OIDC is not configured for production auth |
| `INVALID_ROLE` | Invalid role parameter |
| `STUDENT_ONLY` | Action restricted to the student owner |
| `TEACHER_ONLY` | Action restricted to course teachers |
| `ENTRY_ACCESS_DENIED` | Student does not own this entry |
| `COURSE_ACCESS_DENIED` | User is not a member of this course |
| `TEACHER_REQUIRED` | Teacher role required |
| `NOT_FOUND` | Generic resource not found |
| `ENTRY_NOT_FOUND` | Entry does not exist |
| `ARTIFACT_NOT_FOUND` | Artifact does not exist |
| `COURSE_NOT_FOUND` | Course does not exist |
| `ENTRY_DELETED` | A tombstoned client ID or in-flight operation refers to a deleted entry (410) |
| `ENTRY_LOCKED` | Entry is not in draft status |
| `ENTRY_NOT_SUBMITTED` | Entry must be submitted before this action |
| `ARTIFACTS_NOT_UPLOADED` | All artifacts must be uploaded before submitting |
| `CONSENT_REQUIRED` | Teaching lesson entry requires confirmed consent before submitting |
| `UPLOAD_INVALID` | Upload missing, expired, changed, or different from its declared size |
| `STORAGE_UNAVAILABLE` | Object storage is temporarily unavailable |
| `INVALID_TARGET` | Invalid feedback target type |
| `VALIDATION_ERROR` | Request validation failed |
| `ID_CONFLICT` | Client-generated ID already exists (409) |
| `INTERNAL_ERROR` | Unexpected server error |
| `RATE_LIMITED` | Too many requests |

## Validation Limits

| Limit | Value |
|-------|-------|
| Max duration (entry/artifact) | 28800 seconds (8 hours) |
| Max artifact upload size | 104857600 bytes (100 MiB) |
| Max tags per entry | 30 |
| Max tag length | 100 characters |
| Max feedback/capture markers per request | 50 |
| Max marker text/note length | 1000 characters |
| Max marker timeSeconds | 28800 seconds (8 hours) |
| Max commentsText length | 10000 characters |
| Max auth code length | 2048 characters |
| Default max string length | 10000 characters |
| Client ID format | 1-128 chars, alphanumeric/hyphen/underscore |
| HTTP body size limit | 1 MB |
| Auth rate limit | 10 requests per minute |
| v1 sync admission | 12 requests and 100 commands per authenticated user per minute |
| Sync receipt quota | 500 unexpired successful receipts per user |
| Active artifact sessions | 24 per user; 8 per entry |
| Durable artifacts | 500 artifacts and 10 GiB declared bytes per user |
| Failed artifact retention | 7 days before bounded background pruning |
