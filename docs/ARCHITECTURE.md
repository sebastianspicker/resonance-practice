# Architecture

## Components
- iOS iPad app (SwiftUI): offline-first UI, SwiftData store, background sync queue.
- API server (Fastify + Prisma): auth, course context, entries, feedback, media pre-signed URLs.
- Postgres: metadata and access control.
- Object storage (S3-compatible, MinIO in dev): media artifacts.
- ILIAS: course context via deep link (MVP), optional LTI launch documented.
- ASIMUT: iCal feed consumed directly by app.

## Optional LTI (Minimal)
- If ILIAS supports LTI launch, an LTI 1.3 launch can redirect to the same universal link with `courseId`.
- The MVP does not implement a full LTI platform; it only documents the mapping and relies on deep links.

## Data Flow
1. User signs in via ASWebAuthenticationSession -> app receives auth callback -> exchanges for tokens.
2. App syncs course/membership list into SwiftData.
3. Student creates entry offline -> stored locally -> queued for sync.
4. Sync worker sends metadata to server -> requests pre-signed PUT URL -> uploads media -> confirms upload.
5. Teacher fetches queue -> posts feedback -> student sees feedback on next sync.

## Offline Strategy
- Local-first writes to SwiftData with a persistent sync queue.
- Background sync using URLSession background configuration and exponential backoff.
- Last-write-wins for entry edits; feedback is append-only server-side.

## Pagination
The review queue (`GET /courses/:courseId/review-queue`) uses cursor-based pagination. The response shape is `{ items: [...], nextCursor: string | null }`. Clients pass `?cursor=<entryId>&limit=N` to fetch subsequent pages. The sort order is deterministic: `practiceDate DESC`, `createdAt DESC`, `id DESC` (three-column tiebreaker).

## Error Handling
API returns consistent error objects:
```
{
  "error": {
    "code": "STRING_CODE",
    "message": "Human readable message",
    "details": { "optional": true }
  }
}
```

All error codes are centralized in `errorCodes.ts`. Routes use `withPrismaErrors()` (from `errors.ts`) to translate Prisma-specific exceptions (P2002 unique conflict, P2025 not-found) into structured API errors, avoiding raw 500 responses from database constraint violations.

## Test Coverage
The server has 339 tests across 23 test files covering:
- Authentication and authorization (dev auth, ACL, course-role vs global-role)
- Input validation (client IDs, strings, dates, enums)
- Entry lifecycle (create, update, submit, delete, status transitions)
- Artifact upload flow (presign, confirm, ownership)
- Feedback (creation, permissions, deleted-entry guards)
- Review queue pagination (cursor-based, deterministic ordering)
- Security headers, CORS, rate limiting, and content-type enforcement
- Error handling (structured errors, Prisma error mapping, stack trace suppression)
