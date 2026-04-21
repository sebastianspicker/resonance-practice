# API (Draft)

Base URL: `http://localhost:4000`

All authenticated endpoints require an `Authorization: Bearer <accessToken>` header.

## Response Headers

Every response includes:

- `x-request-id` — a unique identifier for the request, useful for tracing and debugging. Clients should log this value and include it in bug reports to help correlate issues with server-side logs.

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
- `redirectUri` (optional) — the server accepts this but does not validate it in the current (dev) auth implementation. When production auth is introduced, `redirectUri` must be validated against an allowlist or exact match to the registered callback, per OAuth best practice.

Response:
```json
{
  "accessToken": "jwt",
  "refreshToken": "jwt",
  "user": { "id": "...", "displayName": "...", "globalRole": "student|teacher" }
}
```

### POST /auth/refresh
Rotate refresh token.

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

### Production Auth (Design)
- University SSO (Shibboleth) is bridged to an OIDC-compatible authorization server.
- App opens the SSO authorization URL via ASWebAuthenticationSession.
- After login, the server redirects to `resonance://auth-callback?code=...`.
- App exchanges code via `POST /auth/session` using `redirectUri` validation.
- Server validates the authorization code and issues short-lived access token + rotated refresh token.

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

### POST /courses/:courseId/entries
Create an entry. Only students can create entries.

Request:
```json
{
  "id": "client-generated-id",
  "practiceDate": "2025-03-15",
  "goalText": "Work on arpeggios",
  "durationSeconds": 1800,
  "tags": ["technique", "scales"],
  "notes": "Optional free-text notes"
}
```
- `id` (required) — client-generated ID, 1-128 alphanumeric/hyphen/underscore characters. Conflicts return `409 ID_CONFLICT`.
- `practiceDate` (required) — ISO 8601 date (`YYYY-MM-DD`) or datetime with timezone (`YYYY-MM-DDTHH:mm:ssZ`).
- `goalText` (required) — string, max 10000 characters.
- `durationSeconds` (optional) — number, 0-28800 (8 hours).
- `tags` (optional, default `[]`) — string array, max 30 tags, each max 100 characters.
- `notes` (optional) — string or null.

New entries are created with status `draft`.

### PATCH /entries/:entryId
Update entry fields. Only the owning student can edit.

Updatable fields: `goalText`, `practiceDate`, `durationSeconds`, `tags`, `notes`. Only fields present in the request body are updated. Send `null` for `durationSeconds` or `notes` to clear those fields.

Restriction: if the entry status is not `draft`, updating any of these fields returns `409 ENTRY_LOCKED`.

### DELETE /entries/:entryId
Hard-delete entry and associated artifacts/feedback. Storage objects are deleted from S3. Only the owning student can delete.

Response: `204 No Content` (empty body).

### POST /entries/:entryId/submit
Submit an entry for review. Only the owning student can submit.

Preconditions:
- Entry status must be `draft` (otherwise `409 ENTRY_LOCKED`).
- Entry must have at least one artifact, and all artifacts must be in `uploaded` state (otherwise `409 ARTIFACTS_NOT_UPLOADED`).

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
  "type": "audio|video",
  "durationSeconds": 120
}
```
- `id` (required) — client-generated ID, 1-128 alphanumeric/hyphen/underscore characters. Conflicts return `409 ID_CONFLICT`.
- `type` (required) — `"audio"` or `"video"`.
- `durationSeconds` (required) — number, 0-28800 (8 hours).

### POST /artifacts/:artifactId/presign
Request a pre-signed upload URL.

Authorization: only the owning student of the artifact's entry can call this endpoint.

Response includes required request headers for upload:
```json
{
  "uploadUrl": "...",
  "storageKey": "...",
  "expiresInSeconds": 900,
  "requiredHeaders": { "Content-Type": "audio/m4a|video/mp4" }
}
```

Content-Type is determined by artifact type: `audio/m4a` for audio, `video/mp4` for video.

### POST /artifacts/:artifactId/confirm
Confirm upload (server performs HEAD to verify the object exists and is non-empty).

Authorization: only the owning student of the artifact's entry can call this endpoint.

Errors:
- `400 MISSING_STORAGE_KEY` — presign was not called first.
- `409 UPLOAD_INVALID` — object not found in storage or is empty.

## Feedback

### GET /courses/:courseId/review-queue
Teacher-only list of submitted entries with cursor-based pagination.

**BREAKING CHANGE (v0.2):** Response shape changed from a bare array `[...]` to `{ items: [...], nextCursor: string | null }`.

Optional query parameters:
- `limit` — number of items per page (default 20, max 100). Values below 1 return `400 VALIDATION_ERROR`.
- `cursor` — entry ID from a previous `nextCursor` value. The server returns items ordered *after* this entry. Invalid cursor IDs return `400 VALIDATION_ERROR`.

Response:
```json
{
  "items": [
    {
      "id": "...",
      "courseId": "...",
      "studentId": "...",
      "studentName": "...",
      "practiceDate": "...",
      "goalText": "...",
      "notes": "...",
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

Request:
```json
{
  "targetType": "entry|artifact",
  "targetId": "...",
  "status": "ok|needs_revision|next_goal",
  "commentsText": "Great progress on your scales.",
  "markers": [
    { "timeSeconds": 45.2, "text": "Intonation slipped here" }
  ]
}
```
- `targetType` (required) — `"entry"` or `"artifact"`.
- `targetId` (required) — ID of the entry or artifact.
- `status` (required) — `"ok"`, `"needs_revision"`, or `"next_goal"`.
- `commentsText` (required) — string, max 10000 characters.
- `markers` (optional, default `[]`) — array of time-stamped annotations, max 50 markers.
  - `timeSeconds` (required) — number, 0-28800.
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
      { "id": "...", "timeSeconds": 45.2, "text": "..." }
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
| `REFRESH_ALREADY_USED` | Refresh token was already consumed (replay) |
| `INVALID_CODE` | Authorization code is invalid or expired |
| `USER_NOT_FOUND` | User does not exist |
| `DEV_AUTH_LOCAL_ONLY` | Dev auth routes only available from localhost |
| `AUTH_NOT_CONFIGURED` | Production auth is not yet implemented |
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
| `UPLOAD_INVALID` | Upload not found or empty in storage |
| `MISSING_STORAGE_KEY` | Presign not called before confirm |
| `INVALID_TARGET` | Invalid feedback target type |
| `VALIDATION_ERROR` | Request validation failed |
| `ID_CONFLICT` | Client-generated ID already exists (409) |
| `INTERNAL_ERROR` | Unexpected server error |
| `RATE_LIMITED` | Too many requests |

## Validation Limits

| Limit | Value |
|-------|-------|
| Max duration (entry/artifact) | 28800 seconds (8 hours) |
| Max tags per entry | 30 |
| Max tag length | 100 characters |
| Max markers per feedback | 50 |
| Max marker text length | 1000 characters |
| Max marker timeSeconds | 28800 seconds (8 hours) |
| Max commentsText length | 10000 characters |
| Max auth code length | 2048 characters |
| Default max string length | 10000 characters |
| Client ID format | 1-128 chars, alphanumeric/hyphen/underscore |
| HTTP body size limit | 1 MB |
| Auth rate limit | 10 requests per minute |
