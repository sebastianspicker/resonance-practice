# Architecture

## System Overview

```mermaid
flowchart TB
    subgraph Client["iOS iPad App (SwiftUI)"]
        UI[Views]
        SD[SwiftData / Local Store]
        SQ[Sync Queue]
        AM[AuthManager]
    end

    subgraph Server["API Server (Fastify + Prisma)"]
        API[Route Handlers]
        SVC[Services]
        DB[(PostgreSQL)]
        S3[(Object Storage\nMinIO / S3)]
    end

    subgraph External["Configured External Systems"]
        ICAL[User-provided\niCal feed]
        SSO[University SSO\nShibboleth / OIDC]
    end

    UI --> SD
    UI --> SQ
    SQ -->|"sync tasks (HTTPS)"| API
    AM -->|"auth token exchange"| API
    API --> SVC
    SVC --> DB
    SVC --> S3
    AM -.->|"login (prod)"| SSO
    UI -.->|"iCal subscription"| ICAL
```

## Entry Lifecycle

```mermaid
stateDiagram-v2
    [*] --> draft : student creates entry (offline)
    draft --> draft : student edits / attaches media
    draft --> submitted : student submits
    submitted --> reviewed : teacher posts feedback
    reviewed --> [*] : entry deleted (cascade)
    draft --> [*] : entry deleted (cascade)
    submitted --> [*] : entry deleted (cascade)
```

## Components

- iOS iPad app (SwiftUI): offline-first UI, SwiftData store, background sync queue.
- API server (Fastify + Prisma): auth, course context, entries, feedback, media pre-signed URLs.
- Postgres: metadata and access control.
- Object storage (S3-compatible, MinIO in dev): media artifacts.
- External course/LTI integration is proposed but not implemented.
- Calendar events are read from a user-provided iCal URL; automatic ASIMUT integration is not implemented.

## Client Structure

The iOS app starts in `ResonanceApp.swift`, opens the shared SwiftData `ModelContainer`, and injects one `AppState` into the SwiftUI tree. `AppState` wires together the long-lived services used by views:

- `AuthManager`: ASWebAuthenticationSession login, keychain-backed token persistence, refresh-token rotation, and logout.
- `APIClient`: typed HTTP wrapper for the Fastify API and the S3-compatible presign/confirm flow.
- `SyncManager`: background-safe queue coordinator; delegates persistence to `QueueStore`, retry decisions to `RetryPolicy`, and concrete network work to `TaskExecutor`.
- `NetworkMonitor`: reachability gate so offline queue items wait instead of failing immediately.

## Server Structure

```
server/src/
  routes/          # Fastify route handlers (auth, courses, entries, artifacts, feedback)
  services/        # Business logic extracted from routes
    entryCascade.ts  # Artifact + storage cleanup on entry delete
  auth.ts          # JWT sign/verify, token issuance, refresh rotation
  config.ts        # Env-var parsing and startup validation
  errors.ts        # ApiError class, withPrismaErrors wrapper
  errorCodes.ts    # Centralized error code constants
  validation.ts    # Input validation helpers (requireString, requireEntryAccess, …)
  server.ts        # Fastify factory; registers all plugins and route handlers
```

## iOS Sync Architecture

The sync subsystem is split into four focused components:

- **`SyncManager`** — thin coordinator: auth-refresh gating, network check, queue state machine (fetching ready items, applying retry decisions, updating status). Does not contain business logic.
- **`QueueStore`** — all SwiftData I/O: enqueue, fetchReady, fetchFailed, counts, status mutations, artifact state helpers.
- **`TaskExecutor`** — executes a single queue item against the API: one `switch` over `SyncTaskType`, handles idempotency (409 = success for creates, 404 = success for deletes).
- **`RetryPolicy`** — stateless: exponential backoff calculation, terminal-error classification (validation errors, local-not-found, permission errors are immediately terminal; transient network errors are retried).
- **`EntryDeletionCoordinator`** — coordinates offline-safe entry deletion: cancels in-flight queue items for the entry's artifacts, deletes local files, enqueues a remote delete only when the entry was already synced to the server.
- **`CalendarSubscriptionStore`** — persists the iCal subscription URL in Keychain (migrates legacy UserDefaults value on first access).

## Proposed Course Integration

ILIAS/LTI or another course-system deep link may be added later. No LTI launch, universal-link mapping, or automatic course import exists in the current source tree.

## Data Flow

1. User signs in via ASWebAuthenticationSession → app opens `GET /auth/login` → server routes to dev login locally or university OIDC in production → `/auth/oidc/callback` validates, upserts user, issues internal code → app receives `resonance://auth-callback?code=...`.
2. App exchanges internal code via `POST /auth/session` → receives JWT access token + refresh token.
3. App syncs course/membership list into SwiftData.
4. Student creates entry offline → stored locally → queued for sync.
5. Sync worker sends media metadata to server → requests pre-signed PUT URL → uploads media → confirms upload.
6. Practice audio uploads through the normal queue. Teaching-lesson video remains local until the student confirms the private course-review consent scope and starts submission; capture profiles and manual markers provide context for later review without automatic analysis.
7. Student submits entry (`draft → submitted`); teacher fetches review queue.
8. Teacher posts feedback → parent entry transitions to `reviewed` → student sees feedback on next sync.

## Offline Strategy

- Local-first writes to SwiftData with a persistent sync queue.
- Background sync using `URLSession` with `.default` configuration and exponential backoff. Background configuration is intentionally not used because it does not support the Swift concurrency `upload(for:fromFile:)` path used for artifact uploads.
- Last-write-wins for entry edits; feedback is append-only server-side.

## Entry Hydration and Reconciliation

After course refresh, the iOS client reads every student entry page and merges
server metadata and artifacts into SwiftData. `remoteUpdatedAt` distinguishes a
server-backed record from a local-only draft. Newer queued local edits retain
their editable fields while server lifecycle and artifact state continue to
advance. Remote-backed records are pruned only after pagination completes
successfully; an offline launch continues to use the cache.

Queue tasks have an entity identity. Re-enqueueing create/update/submit/delete,
artifact, capture metadata, or feedback replaces the pending payload and resets
its retry state. Submission stays pending while media dependencies are pending.

## Session Data Lifecycle

The Keychain stores the active local-data owner. A different authenticated user
is blocked until the person explicitly deletes the previous local profile or signs out. Manual
sign-out reports pending and failed work, offers sync, and requires confirmation
before deleting courses, entries, media files, feedback, calendar data, exports,
and queue state.

## Teacher Media Playback

Teachers request `GET /artifacts/:artifactId/download`. The server applies entry
membership/ownership authorization and signs an S3 `GetObject` request for 15
minutes. The iOS submission detail streams it through `AVPlayer` and does not
persist a teacher copy. Expiry, offline access, and authorization failures are
implemented as contextual retryable playback states. Device and poor-network behavior still requires pilot validation.

## Pagination

Both the review queue (`GET /courses/:courseId/review-queue`) and the entries list (`GET /courses/:courseId/entries`) use cursor-based pagination. The response shape is `{ items: [...], nextCursor: string | null }`. Clients pass `?cursor=<entryId>&limit=N` to fetch subsequent pages. The sort order is deterministic: `practiceDate DESC`, `createdAt DESC`, `id DESC` (three-column tiebreaker). Default page size is 50, maximum is 200.

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

## Test Surfaces

The checked-in server test suite contains coverage for:

- Authentication and authorization (dev auth, ACL, course-role vs global-role)
- Input validation (client IDs, strings, dates, enums)
- Entry lifecycle (create, update, submit, delete, status transitions, single-entry fetch)
- Artifact upload flow (presign, confirm, ownership)
- Feedback (creation, permissions, deleted-entry guards)
- Review queue pagination and entries list pagination (cursor-based, deterministic ordering)
- Security headers, CORS, rate limiting, and content-type enforcement
- Error handling (structured errors, Prisma error mapping, stack trace suppression)

The latest server tests were not executed in the current local checkout because `server/node_modules` is absent. The iOS XCTest target passed 125 tests locally on 2026-07-11.
