# API Reference

This document describes the routes implemented in the current source tree. It is not evidence of a deployed or externally validated service.

Base URL: `http://localhost:4000`

All authenticated endpoints require an `Authorization: Bearer <accessToken>` header.

## Response Headers

Every response includes:

- `x-request-id` — a unique identifier for the request, useful for tracing and debugging. Clients should log this value and include it in bug reports to help correlate issues with server-side logs.

## Service Probes

- `GET /health` is a process-liveness probe and returns `{ "status": "ok" }` without querying dependencies.
- `GET /ready` checks PostgreSQL and the configured object-storage bucket within the validated dependency deadline. It returns `{ "status": "ready" }` with `200`, or `{ "status": "unavailable" }` with `503`.

## Status Codes

In addition to the error codes listed below, the API uses:

- `201 Created` — returned by `POST` endpoints that create a resource (e.g., `POST /courses/:courseId/entries`, `POST /entries/:entryId/artifacts`, `POST /auth/session`).
- `204 No Content` — returned by `DELETE` endpoints on success (empty body).
- `200 OK` — all other successful responses.

## Auth

### POST /auth/session

Exchange authorization code for tokens.

Rate limit: 10 requests per minute.

Request:
```json
{ "code": "string", "redirectUri": "string" }
```

- `code` (required) — authorization code, max 2048 characters.
- `redirectUri` (optional) — validated in production mode against the registered OIDC callback URI (`OIDC_REDIRECT_URI`) or the app custom scheme (`resonance://auth-callback`). Ignored in dev mode.

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

Revoke all refresh tokens for the authenticated user.

Authorization: requires valid access token.

Response:
```json
{ "success": true }
```

### GET /auth/login

App-facing login entrypoint.

- In `AUTH_MODE=dev`, redirects to `/dev/login` and keeps the localhost-only dev auth guard.
- In `AUTH_MODE=prod`, redirects to `/auth/oidc/login`.

Response: `302 Redirect`.

### GET /auth/oidc/login _(production only)_

Initiates the OIDC authorization flow. Redirects the client to the configured university IdP.

Only available when `OIDC_DISCOVERY_URL`, `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`, and `OIDC_REDIRECT_URI` are set. Returns `501 AUTH_NOT_CONFIGURED` otherwise.

Response: `302 Redirect` → university IdP authorization URL.

### GET /auth/oidc/callback _(production only)_

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

- `role` (required) — `student` or `teacher`.

Redirects to `resonance://auth-callback?code=...`.

#### POST /dev/issue

Issue a dev authorization code programmatically (useful for tests/scripts).

Request:
```json
{ "role": "student|teacher", "userId": "string (optional)" }
```

- `role` (optional, default `"student"`) — create/upsert a persona with this role.
- `userId` (optional) — issue a code for an existing user by ID. If provided, `role` is ignored.

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

- `status` — filter by entry status: `draft`, `submitted`, or `reviewed`. Invalid values return `400 VALIDATION_ERROR`.
  - **Students:** without a filter, all of the student's entries are returned. With a filter, only entries matching that status are returned.
  - **Teachers:** without a filter, only `submitted` entries are returned. With a filter, entries matching that status are returned.
- `limit` — max number of items per page (default: 50, max: 200).
- `cursor` — entry ID of the last item on the previous page. Omit for the first page.

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
- Teachers can fetch any entry in a course they belong to.

Returns `404 ENTRY_NOT_FOUND` if the entry does not exist, `403 ENTRY_ACCESS_DENIED` if the user is not allowed to see it, and `410 ENTRY_DELETED` if the entry has been soft-deleted.

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

- `id` (required) — client-generated ID, 1-128 alphanumeric/hyphen/underscore characters. An exact repeat returns the existing entry with `200`; reusing the ID with different create data returns `409 ID_CONFLICT`.
- `kind` (optional, default `"practice"`) — `"practice"` or `"teaching_lesson"`.
- `practiceDate` (required) — ISO 8601 date (`YYYY-MM-DD`) or datetime with timezone (`YYYY-MM-DDTHH:mm:ssZ`).
- `goalText` (required) — string, max 10000 characters.
- `durationSeconds` (optional) — number, 0-28800 (8 hours).
- `tags` (optional, default `[]`) — string array, max 30 tags, each trimmed tag must be non-empty and max 100 characters.
- `notes` (optional) — string or null.
- `consentConfirmed` (optional) — boolean. Only valid for `teaching_lesson`.
- `consentScope` (optional) — currently `"private_course_review"`. Required when `consentConfirmed` is `true`.
- `captureProfile` (optional) — only valid for `teaching_lesson`. One of `room_overview`, `teacher_learner`, `instrument_closeup`, `ensemble_group`, `group_work`.

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

### POST /entries/:entryId/artifacts

Create an artifact record. Only the owning student can add artifacts, and only to `draft` entries.

Request:
```json
{
  "id": "client-generated-id",
  "type": "audio",
  "durationSeconds": 120,
  "sizeBytes": 1048576
}
```

- `id` (required) — client-generated ID, 1-128 alphanumeric/hyphen/underscore characters. An exact repeat returns the existing artifact with `200`; reusing the ID with different entry, type, duration, or size returns `409 ID_CONFLICT`.
- `type` (required) — `"audio"` or `"video"`.
- `durationSeconds` (required) — number, 0-28800 (8 hours).
- `sizeBytes` (required) — integer, 1-104857600 (100 MiB). The declared size is bound to the signed upload request and verified at confirmation.

### POST /artifacts/:artifactId/presign

Request a pre-signed upload URL.

Authorization: only the owning student of the artifact's entry can call this endpoint.

Response includes required request headers for upload:
```json
{
  "uploadUrl": "...",
  "storageKey": "...",
  "expiresInSeconds": 900,
  "requiredHeaders": {
    "Content-Type": "audio/m4a",
    "Content-Length": "1048576"
  }
}
```

Clients must send every returned header unchanged. Content-Type is `audio/m4a`
for audio artifacts and `video/mp4` for video artifacts. A retry reuses an
unexpired upload slot; expired attempts receive a new storage key and the old
object is queued for cleanup.

Errors:

- `409 UPLOAD_INVALID` — artifact is already uploaded, lacks a declared size, or confirmation is in progress.
- `409 ENTRY_LOCKED` — the parent entry is no longer a draft.

### POST /artifacts/:artifactId/confirm

Confirm upload. The server performs HEAD and requires the stored object size to
exactly match the size declared when the artifact record was created.

Authorization: only the owning student of the artifact's entry can call this endpoint.

Errors:

- `400 MISSING_STORAGE_KEY` — presign was not called first.
- `409 UPLOAD_INVALID` — object is missing, the slot expired or changed, or the object size differs from the declaration.
- `503 STORAGE_UNAVAILABLE` — storage rejected the check or could not be reached.

### GET /artifacts/:artifactId/download

Returns a short-lived URL for private playback. The student owner and a teacher
who belongs to the same course are authorized through the entry access rules.
The artifact must be uploaded, nondeleted, and have a storage key.

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

- `id` (required) — client-generated marker ID, 1-128 alphanumeric/hyphen/underscore characters.
- `artifactId` (required) — video artifact ID belonging to the same entry. Audio artifacts and artifacts from other entries return `404 ARTIFACT_NOT_FOUND`.
- `timeSeconds` (required) — integer, 0-28800.
- `kind` (required) — one of `phase_setup`, `phase_modeling`, `phase_guided_practice`, `phase_student_work`, `phase_feedback`, `phase_reflection`, `moment_question`, `moment_musical_model`, `moment_student_response`, `moment_transition`, `privacy_note`.
- `note` (optional) — free text, max 1000 characters.

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

**BREAKING CHANGE (v0.2):** Response shape changed from a bare array `[...]` to `{ items: [...], nextCursor: string | null }`.

Optional query parameters:

- `limit` — number of items per page (default 20, max 100). Values below 1 return `400 VALIDATION_ERROR`.
- `cursor` — entry ID from a previous `nextCursor` value. The server returns items ordered _after_ this entry. Invalid cursor IDs return `400 VALIDATION_ERROR`.

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

- `id` (optional) — client-generated ID, 1-128 alphanumeric/hyphen/underscore characters.
- `targetType` (required) — `"entry"` or `"artifact"`.
- `targetId` (required) — ID of the entry or artifact.
- `status` (required) — `"ok"`, `"needs_revision"`, or `"next_goal"`.
- `commentsText` (required) — trimmed non-empty string, max 10000 characters.
- `markers` (optional, default `[]`) — array of time-stamped annotations, max 50 markers.
  - `timeSeconds` (required) — integer, 0-28800.
  - `text` (required) — string, max 1000 characters.

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
| `ENTRY_DELETED` | Entry has been soft-deleted (410) |
| `ENTRY_LOCKED` | Entry is not in draft status |
| `ENTRY_NOT_SUBMITTED` | Entry must be submitted before this action |
| `ARTIFACTS_NOT_UPLOADED` | All artifacts must be uploaded before submitting |
| `CONSENT_REQUIRED` | Teaching lesson entry requires confirmed consent before submitting |
| `UPLOAD_INVALID` | Upload missing, expired, changed, or different from its declared size |
| `MISSING_STORAGE_KEY` | Presign not called before confirm |
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
