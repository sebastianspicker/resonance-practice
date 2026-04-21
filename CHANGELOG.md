# Changelog

All notable changes to this project are documented here. For detailed bug reports and required fixes, see [docs/BUGS_AND_FIXES.md](docs/BUGS_AND_FIXES.md).

## [Unreleased]

<!-- Move items here for the next release. -->

## [0.1.0-rc.1] – 2026-04-20

### Security Hardening
- JWT validation constraints: issuer, audience, and algorithm restrictions.
- Auth endpoint rate limiting (10 requests/min per IP).
- Helmet CSP, HSTS, and X-Frame-Options headers on all responses.
- Content-Type enforcement on request bodies.
- Input validation on all endpoints: duration bounds, tag count limits, auth string types, feedback length caps.
- Client ID format validation with 409 Conflict on duplicates.
- npm audit clean: fast-xml-parser upgraded to 5.5.8 (GHSA-jp2q-39xq-3w4g).
- Separate signing keys for access and refresh tokens (`JWT_REFRESH_SECRET`).
- `.env.example` safety warnings for secrets, JWT_SECRET, and AUTH_MODE=dev.
- Refresh token endpoint gated by AUTH_MODE to prevent misuse in dev mode.

### Bug Fixes — Server
- #4: Refresh token rotation atomicity.
- #5/#20: Entry cascade delete ordering — artifact enumeration moved inside `$transaction` for atomic cascade delete.
- #31: Membership lookup consolidation.
- #32: Error response consistency.
- #33: Storage bucket creation guard.
- #34: Upload state validation.
- #35: Presign URL expiry.
- #37: CORS origin validation.
- #38: `ensureBucket` only creates bucket on 404/NotFound/NoSuchBucket.
- #39: Sign-in callback sets error state instead of silent no-op.
- #41: Dev-auth local-only restriction.
- #43: Error code standardization.
- #44: Feedback targetId/targetType validation confirmed with regression tests.
- #48: Block artifact creation on non-draft entries.
- Error handling consistency: Prisma error differentiation, CTP error codes, structured logging.

### Bug Fixes — iOS
- SyncManager: removed force-unwrap and replaced `fatalError` with recoverable error handling.
- SyncManager: fixed data race in background task expiration handler.
- SyncManager: fixed FIFO ordering for sync queue processing.
- SyncManager: fixed background URLSession incompatibility with async upload API.
- Auth callback Task: explicit `@MainActor` annotation to prevent off-main-thread UI updates.
- Fixed orphaned `LocalFeedback`/`LocalMarker` objects on feedback refresh.
- Fixed ExportView date range to include all entries on selected dates.
- Fixed CourseDetailView tab selection resetting on every `onAppear`.
- Fixed CSV tag decoding to trim whitespace for backward compatibility.
- Offline-sync reliability: logging, network guard, token refresh, idempotency documentation.

### Test Coverage
- Server: 25 → 355 tests across 25 test files.
- Unit tests: validation, auth, error handling.
- Integration tests: all CRUD endpoints, ACL, uploads, storage, CORS, dev-auth.
- Edge cases: 54 boundary and error-path tests.
- iOS: 49 XCTest tests — enum raw values, API model decoding, ICalParser edge cases, AppConfig derivation, sync queue.

### Performance
- Eliminated redundant membership queries in entry mutation routes.
- Added composite index on `PracticeEntry(courseId, deletedAt)`.
- Narrowed relation includes to select only needed fields.

### Developer Experience
- `.nvmrc` for Node version consistency.
- `npm audit` added to CI pipeline PR checks.
- Local CI parity: `scripts/ci-local.sh` matches GitHub Actions workflow.
- Docker health checks on Postgres and MinIO containers.
- `docs/API.md` comprehensive rewrite with status filter, pagination, and error codes.
- `docs/CONTRIBUTING.md` and `docs/RUNBOOK.md` accuracy fixes.

### Code Quality
- Removed dead code: unused error codes, validation helpers, Swift imports, unread `@Published` property.
- Standardized import ordering: external packages first, then local modules, alphabetically.
- Normalized error message tone: removed trailing periods from validation messages.
- Fixed Swift diagnostics: removed unused UIKit import, fixed Task capture list syntax.
- Applied Prettier formatting across all server files.

### Prior (pre-improvement rounds)
- RC demo track: added canonical Mock University fixture, demo seed/reset scripts, and local bootstrap script for reproducible screenshot states.
- iOS debug tooling: added local demo dataset loader/clear actions in Settings and bundled fixture for screenshot preparation.
- Documentation: added RC demo runbook, screenshot matrix, and release checklist.
- Repo cleanup: removed redundant `server/prisma/seed.js` (seed uses `seed.ts` only).
- iOS: fixed string interpolation in EntryDetailView error print.
- Server: atomic refresh token rotation; entry delete now runs DB transaction before S3 delete; teacher course entries restricted to `submitted` only.
- Server: test auth helper centralized in testUtils; validation and routes split into `validation.ts` and `routes/*.ts`.
- iOS: shared APIClient via AppState; SyncManager generic fetch-by-id; APIClient send/sendAny consolidated; API DTOs moved to APIModels.swift.
- iOS: central error alerts; SyncManager lastSyncedAt; loading states and "Last synced" in UI; RUNBOOK/SECURITY/API docs updated for dev auth and redirectUri.
