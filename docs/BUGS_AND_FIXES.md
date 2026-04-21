# Bugs & Required Fixes

Each item can be turned into a separate issue.

---

## Known Limitations / Bugs

### 1. [Bug/Operational] Dev auth is unauthenticated and GET-driven — ✅ Mitigated

**Description:** When `AUTH_MODE=dev`, `/dev/login`, `/dev/authorize`, and `/dev/issue` are publicly accessible. Anyone can obtain auth codes and mint sessions; `/dev/issue` can accept an arbitrary `userId` to issue a code for any existing user. The flow is GET-driven with no CSRF or confirmation (e.g. "Login as Teacher" is one click).

**Impact:** If dev server is reachable beyond localhost (misconfig or shared env), full authentication bypass and account takeover.

**Fix:** Keep dev auth strictly local-only (document, and optionally enforce bind to loopback). Do not set `AUTH_MODE=dev` in any reachable environment. For production, implement real SSO and disable dev routes.

**Status:** Mitigated. All dev auth routes enforce loopback-only access (`requireLocalDevAuth`). `AUTH_MODE=dev` will not be set in production. Documentation warns against non-local use. `.env.example` has safety warnings.

**Sources:** README, `docs/SECURITY.md`, `server/src/routes/auth.ts`

---

### 2. [Bug] `redirectUri` is accepted but never validated — Deferred

**Description:** `POST /auth/session` accepts `redirectUri` in the body (and iOS always sends it) but the server does not validate or bind the code to it. Docs state production design will use `redirectUri` validation.

**Impact:** When moving to real OAuth/SSO, lack of redirect binding is a standard code-interception/redirect-abuse vector. Current contract mismatch (client sends, server ignores) is misleading.

**Fix:** Implement `redirectUri` validation when introducing production auth (e.g. allowlist or exact match to registered callback). For dev, document that validation is intentionally skipped.

**Status:** Deferred — will be implemented with production OAuth/SSO. In dev mode, `redirectUri` is intentionally not validated (documented in code comments).

**Sources:** `docs/API.md`, `docs/SECURITY.md`

---

### 3. [Bug/Operational] Dev auth code in URL query (exfil surface) — ✅ Mitigated

**Description:** `/dev/authorize` redirects to `DEV_LOGIN_CALLBACK_URL` with `?code=...`. The auth code is in the query string; there is no validation of the redirect URL. Misconfigured or attacker-controlled callback URL can exfiltrate the code.

**Impact:** Code in URL can appear in history, logs, referrers. Open redirect + code in query is a classic token-theft path.

**Fix:** Validate `DEV_LOGIN_CALLBACK_URL` (scheme/host allowlist). Prefer passing code in fragment or via POST callback where feasible for production design.

**Status:** Mitigated. `validateDevCallbackUrl` in `config.ts` validates at startup that `DEV_LOGIN_CALLBACK_URL` starts with `resonance://` or `http://localhost`. Other schemes are rejected. Unit tests cover allowed and disallowed schemes.

**Sources:** `server/src/config.ts`, `server/tests/validation.test.ts`

---

### 4. [Bug] Refresh token rotation is not atomic — ✅ Fixed

**Description:** `rotateRefreshToken` reads the refresh token record, updates `revokedAt`, then issues new tokens. Steps are not in a transaction and revocation is not conditional on `revokedAt` being null. Two concurrent requests with the same refresh token can both pass validation and each get new tokens.

**Impact:** Single-use refresh token guarantee can be violated; token duplication and harder containment after theft.

**Fix:** Wrap read → conditional update (e.g. "revoke where revokedAt is null") → issue in a transaction, or use a single atomic "claim and revoke" (e.g. conditional update by id + revokedAt).

**Status:** Fixed. `rotateRefreshToken` now wraps the entire flow in `prisma.$transaction`, uses `updateMany` with `revokedAt: null` conditional, and checks `updateResult.count === 0` to detect race conditions.

**Sources:** `server/src/auth.ts`

---

### 5. [Bug] Entry delete: S3 delete before DB transaction (inconsistent state on failure) — ✅ Fixed (ordering)

**Description:** `DELETE /entries/:entryId` deletes S3 objects first, then runs a Prisma transaction for DB deletes. If the transaction fails (or S3 delete partially fails), DB can still reference deleted objects, or artifacts can remain in DB with storage already removed.

**Impact:** Irrecoverable DB/storage mismatch; broken playback or orphaned blobs; partial deletion with no clear recovery.

**Fix applied:** Delete logic moved to `server/src/services/entryCascade.ts`. `cascadeDeleteEntry` runs all DB deletes in a single Prisma `$transaction`; `cleanupS3Objects` is called only after the transaction succeeds. S3 failures are logged but don't throw — orphaned objects can be cleaned up separately. Artifact enumeration (for storage key collection) still happens outside the transaction; see #20 for the remaining prefetch concern.

**Sources:** `server/src/services/entryCascade.ts`

---

### 6. [Bug] Teacher course listing returns all entries (including drafts) — ✅ Fixed

**Description:** `GET /courses/:courseId/entries` for a teacher returns all non-deleted entries in the course (no `status` filter). Drafts are included, unlike the dedicated review queue which filters `status: 'submitted'`.

**Impact:** Teachers can see draft practice notes and in-progress artifacts outside the intended "review queue" boundary; may violate product expectation that drafts are student-only.

**Fix:** Either restrict this endpoint for teachers to `status: 'submitted'` (or document that teachers intentionally see all entries). Align with review queue semantics.

**Status:** Fixed. Teacher listing in `GET /courses/:courseId/entries` now defaults to `status: 'submitted'` when no filter is provided. An explicit `?status=` query parameter allows overriding.

**Sources:** `server/src/routes/courses.ts`

---

### 7. [Bug/Config] iOS dev login URL hardcoded to localhost — ✅ Fixed

**Description:** `AppConfig.devLoginURL` is fixed to `http://localhost:4000/dev/login`, independent of `RESONANCE_API_BASE`. On a physical device, localhost is the device; auth breaks. API and login can target different hosts.

**Impact:** Auth fails in common on-device or multi-host dev setups; confusing and unsafe config drift.

**Fix:** Derive dev login URL from the same base as API (e.g. `apiBaseURL.appendingPathComponent("dev/login")`) or a dedicated but configurable env var.

**Status:** Fixed. `devLoginURL` is now derived from `apiBaseURL`: `static let devLoginURL = apiBaseURL.appendingPathComponent("dev/login")`.

**Sources:** `ios/ResonanceApp/Sources/AppConfig.swift`

---

### 8. [Bug/Config] Keychain not namespaced by environment — ✅ Fixed

**Description:** Auth session is stored in Keychain with fixed keys. `RESONANCE_API_BASE` can point at different servers, but Keychain is shared; switching API base can reuse tokens against the wrong backend.

**Impact:** Cross-environment token reuse; confusing auth failures or tokens sent to wrong server.

**Fix:** Include environment/server identifier in Keychain keys (e.g. hash of API base or explicit "dev"/"prod" key suffix).

**Status:** Fixed. `AppConfig.keychainNamespace` is derived from `apiBaseURL` (sanitized to alphanumeric). `KeychainStore` prepends this namespace to all Keychain account keys. OSStatus errors are also logged.

**Sources:** `ios/ResonanceApp/Sources/AppConfig.swift`, `ios/ResonanceApp/Sources/KeychainStore.swift`

---

## Required Fixes / Improvements

### 9. [Enhancement] Use course role, not global role, for entry/artifact authorization — ✅ Fixed

**Description:** Many routes use `user.role` from the JWT (global role) instead of `roleInCourse` from membership. `requireEntryAccess` only restricts "owner" when `user.role === 'student'`, so a user with global teacher but course student can access any entry in that course (IDOR). Presign/confirm and feedback similarly mix global vs course role.

**Fix:** Use `requireCourseRole()` result for authorization decisions (e.g. "can edit own entry" when `roleInCourse === 'student'`, "can confirm artifact" only for owning student or course teacher). Unify on course role for all course-scoped operations.

**Status:** Fixed. All routes now use `requireCourseRole()`, `requireStudentOwner()`, and `requireTeacherRole()` from `validation.ts` for course-scoped authorization. `requireEntryAccess` uses `roleInCourse` (not `user.role`) for the ownership check.

**Sources:** `server/src/validation.ts`, `server/src/routes/entries.ts`, `server/src/routes/artifacts.ts`, `server/src/routes/feedback.ts`

---

### 10. [Enhancement] Enforce student ownership on artifact confirm (and align with presign) — ✅ Fixed

**Description:** `POST /artifacts/:artifactId/confirm` checks only course membership; it does not enforce that a student is the owner of the artifact's entry. Presign does enforce student ownership. Any course member can confirm any artifact.

**Fix:** Add the same ownership check as presign: if `user.role === 'student'` (or course role is student), require `artifact.entry.studentId === user.id`.

**Status:** Fixed. Artifact confirm now uses `requireStudentOwner()` — same as presign and artifact creation.

**Sources:** `server/src/routes/artifacts.ts`

---

### 11. [Enhancement] Validate and document `redirectUri` for production auth — Deferred

Same as (2): Implement and document `redirectUri` validation when production auth is added.

**Status:** Deferred — same as #2. Will be implemented with production OAuth/SSO.

---

### 12. [Enhancement] Server-side logout / refresh token revocation — ✅ Fixed

**Description:** No `/auth/logout` (or similar); iOS `signOut()` only clears local state. Refresh tokens remain valid until expiry.

**Fix:** Add an endpoint that revokes the current refresh token (and optionally all refresh tokens for the user). Call it from the client on sign-out.

**Status:** Fixed. `POST /auth/logout` (authenticated) revokes all active refresh tokens for the user. iOS `signOut()` calls `apiClient.logout()` before clearing local credentials.

**Sources:** `server/src/routes/auth.ts`, `ios/ResonanceApp/Sources/AuthManager.swift`, `ios/ResonanceApp/Sources/APIClient.swift`

---

### 13. [Enhancement] Clearer error handling and validation (entries, PATCH, notes) — ✅ Fixed

**Description:** PATCH `/entries/:entryId` does not validate `goalText`/`notes` type (can 500). Submitted-entry lock checks use truthiness, so `goalText: ""` or `durationSeconds: 0` bypass the lock. Nullable fields (notes, durationSeconds) cannot be cleared via PATCH.

**Fix:** Use `requireString`/type checks for goalText and notes on PATCH; enforce submitted-entry lock with "field present in body" (e.g. `body.goalText !== undefined`) instead of truthiness; allow explicit null to clear nullable fields.

**Status:** Fixed. PATCH route uses `'goalText' in body` (field presence) for the submitted-entry lock, `requireString`/`requireNumber` for type validation, and allows explicit `null` to clear nullable fields (`notes`, `durationSeconds`).

**Sources:** `server/src/routes/entries.ts`

---

### 14. [Operational] Test suite must not TRUNCATE non-test database — ✅ Fixed

**Description:** Vitest setup uses existing `DATABASE_URL` if set; `resetDb()` runs `TRUNCATE ... CASCADE` on core tables. Running tests against a real DB can wipe data.

**Fix:** Force a test-only database in test setup (e.g. require `DATABASE_URL` to contain a test marker, or use a fixed test URL when not in CI). Document that `npm test` must never point at production/staging.

**Status:** Fixed. `vitest.setup.ts` checks that `DATABASE_URL` contains the string `test` (case-insensitive) and calls `process.exit(1)` if it does not. Default test URL uses `resonance_test` database.

**Sources:** `server/tests/vitest.setup.ts`

---

### 15. [Enhancement] Keychain status codes and single-flight refresh (iOS) — ✅ Fixed

**Description:** Keychain set/get/delete ignore OSStatus; failures are silent. `refreshIfNeeded()` has no single-flight/lock; concurrent refresh can cause one request to invalidate the other's token and trigger sign-out despite a successful refresh elsewhere.

**Fix:** Check Keychain status in set/delete/add and surface or retry on failure. Add a lock or single-flight for refresh so only one refresh runs at a time and callers await the same result.

**Status:** Fixed. `KeychainStore` now checks and logs `OSStatus` on set/get/delete. `AuthManager.refreshIfNeeded()` uses a `refreshTask` property as a single-flight lock — concurrent callers await the same task.

**Sources:** `ios/ResonanceApp/Sources/KeychainStore.swift`, `ios/ResonanceApp/Sources/AuthManager.swift`

---

---

## Critical

### 16. [Bug] requireEntryAccess uses global role → IDOR for non-student global role — ✅ Fixed

**Description:** Ownership check is `if (user.role === 'student' && entry.studentId !== user.id)`. Users with global role teacher but course role student skip the check and can access any entry in the course.

**Fix:** Use course role from `requireCourseRole()`: restrict "own entries only" when course role is student, not when global role is student.

**Status:** Fixed. `requireEntryAccess` now calls `requireCourseRole()` and checks `roleInCourse === 'student'` for the ownership guard. Returns `roleInCourse` for downstream use.

**Sources:** `server/src/validation.ts`

---

### 17. [Bug] Artifact confirm has no ownership/role check — ✅ Fixed

**Description:** Any course member can call `POST /artifacts/:artifactId/confirm` and mutate uploadState/remoteUrl for any artifact in the course.

**Fix:** Enforce student ownership (same as presign): student must be `artifact.entry.studentId`; teacher in course can remain allowed if product agrees.

**Status:** Fixed. Artifact confirm route now calls `requireStudentOwner()` to enforce that only the owning student can confirm.

**Sources:** `server/src/routes/artifacts.ts`

---

### 18. [Bug] Presign allows global-teacher to get PUT URLs for others' artifacts (overwrite risk) — ✅ Fixed

**Description:** Presign only restricts students; global teacher in course can presign any artifact. Storage key is deterministic; overwrite of existing object is possible.

**Fix:** Restrict presign to owning student (and optionally teacher for a defined flow). Use course role, not global role.

**Status:** Fixed. Presign route now calls `requireStudentOwner()` — only the owning student can obtain a presigned upload URL.

**Sources:** `server/src/routes/artifacts.ts`

---

### 19. [Bug] Feedback route uses global role; course-teacher not enforced — ✅ Fixed

**Description:** POST `/feedback` and GET `/entries/:entryId/feedback` rely on global role or requireEntryAccess. A global teacher enrolled as student in a course can leave feedback; a global student with course role teacher cannot (inconsistent).

**Fix:** Use course role for "may post feedback" and "may read feedback" (e.g. require `roleInCourse === 'teacher'` for posting; visibility by entry access using course role).

**Status:** Fixed. `POST /feedback` uses `requireCourseRole()` and checks `roleInCourse !== 'teacher'` to reject non-course-teachers. `GET /entries/:entryId/feedback` uses `requireEntryAccess` which internally uses course role.

**Sources:** `server/src/routes/feedback.ts`, `server/src/routes/entries.ts`

---

### 20. [Bug] Entry delete: orphaned feedback and storage (non-transactional prefetch + S3 before DB) — ✅ Fixed

**Description:** Artifacts are fetched outside the transaction; feedback is deleted by prefetched artifact IDs; then entry (and artifacts) are deleted. Cascade can remove artifacts not in the prefetch list, orphaning their feedback. S3 delete runs before transaction; DB failure leaves DB referencing missing storage.

**Status:** Fully fixed. S3-before-DB ordering was fixed in #5. Artifact enumeration (`findMany`) is now inside the `$transaction` callback, ensuring the artifact list and all cascade deletes are atomic. Storage keys are returned from the transaction for subsequent S3 cleanup.

**Sources:** `server/src/services/entryCascade.ts`

---

### 21. [Bug] Presign Content-Type vs client upload (no Content-Type header) — ✅ Fixed

**Description:** Server presigns with `ContentType: audio/m4a` or `video/mp4` but does not return required headers; iOS upload does not set `Content-Type`. Signature mismatch or wrong metadata can break uploads or type enforcement.

**Fix:** Either require client to send the same Content-Type on PUT (and document it), or use a presign policy that does not require Content-Type to be sent by client; align server and iOS.

**Status:** Fixed. Server presign response now includes `requiredHeaders: { 'Content-Type': contentType }`. iOS `uploadFile` reads `presign.requiredHeaders` and sets them on the upload request.

**Sources:** `server/src/routes/artifacts.ts`, `ios/ResonanceApp/Sources/SyncManager.swift`, `ios/ResonanceApp/Sources/APIModels.swift`

---

### 22. [Bug] Sync queue: payload parse failure and unknown type → silent delete (data loss) — ✅ Fixed

**Description:** If `payloadJSON` fails to parse as a dictionary, `process(item:)` returns without throwing; the queue item is deleted. Unknown `SyncTaskType` also falls through and item is deleted. Invalid presign URL causes upload to be skipped but item is still deleted.

**Fix:** On parse failure or unknown type, throw (or mark item failed) so the item is not deleted and can retry or be surfaced. Validate presign URL and throw if invalid before considering upload done.

**Status:** Fixed. `process(item:)` now throws `SyncError.payloadParseError` on parse failure, `SyncError.unknownTaskType` for unrecognized types, and `SyncError.invalidPresignUrl` for invalid URLs. All `SyncError` variants are caught and mark the item as `"failed"` (non-retryable) instead of deleting.

**Sources:** `ios/ResonanceApp/Sources/SyncManager.swift`

---

### 23. [Bug] Tests can TRUNCATE non-test database — ✅ Fixed

Same as (14): Force test DB in setup; never use production/staging URL for `resetDb()`.

**Status:** Fixed (same as #14). See #14 for details.

**Sources:** `server/tests/vitest.setup.ts`

---

### 24. [Bug] /auth/session does not validate redirectUri — Deferred

Same as (2): Code exchange does not bind or validate `redirectUri`.

**Status:** Deferred — will be implemented with production OAuth/SSO.

**Sources:** `server/src/server.ts`

---

### 25. [Bug] ATS disabled (NSAllowsArbitraryLoads = true) — ✅ Fixed

**Description:** App Transport Security was disabled globally; plain HTTP and weak TLS were allowed. Sensitive data (tokens, media) could be sent over insecure transport.

**Fix:** Enable ATS; use HTTPS for API base. If localhost HTTP is required for dev, restrict exception to localhost with a narrow plist exception.

**Status:** Fixed. `NSAllowsArbitraryLoads` is now `false`. A narrow `NSExceptionDomains` entry permits insecure HTTP only to `localhost` (for local dev). All other connections require HTTPS/ATS.

**Sources:** `ios/ResonanceApp/Sources/Resources/Info.plist`

---

### 26. [Bug] File protection / backup exclusion on new audio files ineffective — ✅ Fixed

**Description:** `setFileProtection(url:)` is called on a URL before the file exists; errors are swallowed with `try?`. Newly created recordings may not get the intended protection or backup exclusion.

**Fix:** Create the file first, then set resource values and attributes; check and handle errors (or at least log).

**Status:** Fixed. `setFileProtection(url:)` now guards with `FileManager.fileExists(atPath:)` and logs a warning for non-existent paths. Errors in `setResourceValues` and `setAttributes` are caught and logged (not swallowed).

**Sources:** `ios/ResonanceApp/Sources/FileStore.swift`

---

### 27. [Bug] createEntry JSON body: Optional.none as Any breaks JSONSerialization — ✅ Fixed

**Description:** iOS builds `[String: Any]` with `durationSeconds as Any` and `notes as Any`. When nil, Swift can put `Optional.none` in the dict; `JSONSerialization` cannot encode it and throws. Common for "no notes" entries.

**Fix:** Omit optional keys when nil, or use a type that encodes to JSON null explicitly (e.g. encode only when non-nil, or use a custom encoder).

**Status:** Fixed. `createEntry` now uses a typed `Encodable` struct with a custom `encode(to:)` that only encodes non-nil optionals. No more `[String: Any]` or `JSONSerialization`.

**Sources:** `ios/ResonanceApp/Sources/APIClient.swift`

---

### 28. [Bug] iOS date decoding (.iso8601) vs server Date (fractional seconds) — ✅ Fixed

**Description:** Server returns Prisma DateTime as JSON dates (often with fractional seconds). iOS uses `JSONDecoder.dateDecodingStrategy = .iso8601`; strict ISO8601 may reject fractional seconds and cause decode failures on entries, review queue, feedback.

**Fix:** Use a custom date decoding strategy that accepts fractional seconds (e.g. ISO8601DateFormatter with `.withFractionalSeconds`), or ensure server serializes dates in a format the client accepts.

**Status:** Fixed. `JSONDecoder.apiDecoder` uses a `.custom` date strategy that tries `ISO8601DateFormatter` with `.withFractionalSeconds` first, then falls back to without. Both formatters are created once (not per-decode).

**Sources:** `ios/ResonanceApp/Sources/APIClient.swift`

---

### 29. [Bug] POST /feedback response omits teacherName; iOS FeedbackResponse expects it — ✅ Fixed

**Description:** Server returns feedback with `teacherName` from `item.teacher.displayName`, but if the mapping or include is wrong, the field can be missing. iOS model has non-optional `teacherName` → decode crash.

**Fix:** Guarantee `teacherName` (or equivalent) in response and align type; or make iOS property optional and handle missing.

**Status:** Fixed. `POST /feedback` response includes `teacherName: feedback.teacher.displayName` (teacher relation is included in the query). `GET /entries/:entryId/feedback` also maps `teacherName`.

**Sources:** `server/src/routes/feedback.ts`, `server/src/routes/entries.ts`

---

### 30. [Bug] .env.example deploy-dangerous auth and placeholders — ✅ Fixed

**Description:** Example env can suggest `AUTH_MODE=dev` or credential-like placeholders that are unsafe if used in production.

**Fix:** Document that dev auth must not be used in production; use safe placeholders and point to real secret management.

**Status:** Fixed. `.env.example` has safety warnings at the top and inline: "Do NOT use these placeholder values in production", "Replace with a strong random secret", "dev disables real authentication — use ONLY on localhost". JWT_SECRET placeholder prompts generation via `openssl rand`.

**Sources:** `server/.env.example`

---

## High

### 31. [Bug] JWT no iss/aud/algorithms constraints — ✅ Fixed

**Description:** Sign/verify use minimal options; no issuer, audience, or algorithm allowlist. **Fix:** Set and verify `iss`/`aud` where applicable; pass `algorithms` to `jwt.verify`. **Sources:** `server/src/auth.ts`

**Status:** Fixed. `JWT_ISSUER`, `JWT_AUDIENCE`, and `JWT_ALGORITHM` constants are defined and passed to all `jwt.sign` and `jwt.verify` calls. `algorithms` allowlist is set to `['HS256']` in verify.

---

### 32. [Bug] Token TTL env (ACCESS_TOKEN_TTL_MINUTES, REFRESH_TOKEN_TTL_DAYS) unvalidated — ✅ Fixed

**Description:** `Number(...)` can yield NaN; negative/zero accepted. **Fix:** Validate range and numeric; fail startup on invalid. **Sources:** `server/src/config.ts`

**Status:** Fixed. `config.ts` now validates both values with `Number.isNaN` and `<= 0` checks, throwing on invalid input.

---

### 33. [Bug] /auth/refresh not gated by AUTH_MODE — ✅ Fixed

**Description:** In prod, `/auth/session` returns 501 but `/auth/refresh` is still callable. **Fix:** Gate refresh by auth mode or document intentional behavior. **Sources:** `server/src/routes/auth.ts`

**Status:** Fixed. `/auth/refresh` now checks `config.authMode !== 'dev'` and returns 501 when production auth is not configured.

---

### 34. [Bug] deletedAt not enforced on artifact/feedback routes — ✅ Fixed

**Description:** Artifact and feedback routes do not check `entry.deletedAt` (or artifact's entry deleted). **Fix:** After loading entry/artifact, reject with 410 if entry is deleted. **Sources:** `server/src/routes/artifacts.ts`, `server/src/routes/feedback.ts`

**Status:** Fixed. All artifact routes (create, presign, confirm) and feedback routes check `entry.deletedAt` and return 410 if the entry has been deleted.

---

### 35. [Bug] Client-controlled entry/artifact IDs with no format validation — ✅ Fixed

**Description:** Client supplies primary keys; no format/length validation; duplicate ID can 500. **Fix:** Validate format (e.g. UUID or allowlist); return 409 on conflict. **Sources:** `server/src/routes/entries.ts`, `server/src/routes/artifacts.ts`, `server/src/validation.ts`

**Status:** Fixed. `requireClientId` validates IDs against `/^[a-zA-Z0-9_-]{1,128}$/`. Both entry and artifact creation catch Prisma P2002 and return 409.

---

### 36. [Bug] Submitted-entry edit lock bypass via falsy values — ✅ Fixed

**Description:** Lock uses `if (body.goalText || ...)` so "" or 0 bypass. **Fix:** Check "field present" (e.g. `body.hasOwnProperty('goalText')`) instead of truthiness.

**Status:** Fixed. PATCH route now uses `'goalText' in body` (the `in` operator) for all restricted fields instead of truthiness checks. Same as #13.

**Sources:** `server/src/routes/entries.ts`

---

### 37. [Bug] Presign reuses storageKey and sets uploadState to uploading (overwrite + state regression) — ✅ Fixed

**Description:** Repeated presign overwrites same key and can set already-uploaded artifact back to uploading. **Fix:** Do not overwrite storageKey if already set; do not set uploadState to uploading if already uploaded; or issue new key for each presign. **Sources:** `server/src/routes/artifacts.ts`

**Status:** Fixed. Presign now uses `artifact.storageKey ?? <generated>` (preserves existing key) and only updates `uploadState` to `'uploading'` when `artifact.uploadState !== 'uploaded'`.

---

### 38. [Bug] ensureBucket treats any HeadBucket error as "missing" (CreateBucket race/wrong error) — ✅ Fixed

**Description:** Any error from HeadBucket leads to CreateBucket; access denied or TLS errors can cause wrong behavior or multi-instance race. **Fix:** Only create on 404/NoSuchBucket; rethrow others; or use idempotent create where supported. **Sources:** `server/src/storage.ts`

**Status:** Fixed. `ensureBucket` now only attempts `CreateBucket` when the error is `NotFound`, `NoSuchBucket`, or HTTP 404. All other errors (403 AccessDenied, network/TLS, etc.) are rethrown.

---

### 39. [Bug] Sign-in callback: missing code or parse failure → silent no-op — ✅ Fixed

**Description:** If callback URL or `code` is missing/unparseable, AuthManager returns without error or state update. **Fix:** Set error state or show user-visible error; do not silently no-op. **Sources:** `ios/ResonanceApp/Sources/AuthManager.swift`

**Status:** Fixed. Added `@Published var authError: String?` to `AuthManager`. All failure paths in the sign-in callback (error from auth session, missing callback URL, missing code parameter, code exchange failure) now set `authError` with a descriptive message. User-cancelled sign-in does not set error. `authError` is cleared on sign-in start and on successful session persist.

---

### 40. [Bug] SwiftData fetch/save errors swallowed in SyncManager — ✅ Fixed

**Description:** `try?` on fetch/save; enqueue can silently fail to persist. **Fix:** Propagate or handle errors; distinguish "empty queue" from "fetch failed".

**Status:** Fixed. `saveContext()` uses `do/catch` and logs errors. Queue fetches use `do/catch` with early return on failure (logged). `fetchFirst` throws on missing items. All fetch paths log errors instead of swallowing.

**Sources:** `ios/ResonanceApp/Sources/SyncManager.swift`

---

### 41. [Bug] SyncManager predicate force-unwrap nextAttemptAt in #Predicate — ✅ Fixed

**Description:** `item.nextAttemptAt! <= now` in predicate can be unsafe under SwiftData translation. **Fix:** Avoid force-unwrap in predicate; use optional binding or a safe expression. **Sources:** `ios/ResonanceApp/Sources/SyncManager.swift`

**Status:** Fixed. Predicate now uses `(item.nextAttemptAt ?? .distantFuture) <= now` instead of force-unwrap.

---

### 42. [Bug] Media directory protection only on first creation; errors swallowed — ✅ Fixed

**Description:** `setFileProtection` only when directory does not exist; creation errors ignored. **Fix:** Ensure protection after create; handle and optionally retry or log errors.

**Status:** Fixed. `mediaDirectory()` calls `setFileProtection` after directory creation. `setFileProtection` guards file existence, uses `do/catch`, and logs errors. Directory creation errors are also caught and logged.

**Sources:** `ios/ResonanceApp/Sources/FileStore.swift`

---

### 43. [Bug] ModelContainer failure → fatalError (crash at launch) — ✅ Fixed

**Description:** SwiftData container creation failure calls `fatalError`. **Fix:** Surface error to user (e.g. alert + safe state) or recover; avoid fatalError in production. **Sources:** `ios/ResonanceApp/Sources/Persistence.swift`

**Status:** Fixed. `createContainer` now attempts recovery: deletes corrupt store files and retries, then falls back to in-memory store. Only fatalErrors if even an in-memory container fails (schema-level programmer error).

---

### 44. [Bug] Feedback targetId/targetType no FK (integrity only in app code) — ✅ Mitigated

**Description:** Feedback has no DB FK to entry/artifact; orphaned or invalid targets possible if any code path inserts without checks. **Fix:** Document and keep all insertion paths validated; optionally add DB constraints or triggers. **Sources:** `server/prisma/schema.prisma`, `server/src/routes/feedback.ts`

**Status:** Mitigated. There is only one feedback insertion path (`POST /feedback` in `routes/feedback.ts`), and it fully validates the target: looks up the entry/artifact by `targetId`, rejects 404 if not found, rejects 410 if deleted, rejects 409 if not submitted, and requires the user to be a course teacher. A DB FK is not feasible for polymorphic targetType (entry/artifact), so app-layer validation is the correct approach. Added regression test to verify that feedback creation with invalid targetId is rejected.

---

### 45. [Bug] Prisma ON DELETE CASCADE on core relations (large irreversible loss) — ✅ Mitigated (documented)

**Description:** Cascade deletes can remove large amounts of data in one go. **Fix:** Document and consider softer delete or narrower cascade where appropriate.

**Status:** Mitigated. Added a documentation comment block in `schema.prisma` above the `User` model explaining: which cascades exist, what gets deleted, and recommending soft-delete / archiving / admin-only paths for production. Schema behavior is unchanged — this is a documentation + awareness fix.

**Sources:** `server/prisma/schema.prisma`

---

### 46. [Bug] Multiple critical routes untested (submit, feedback GET, auth/me, course detail, dev/authorize) — ✅ Fixed

**Description:** No tests for submit, entry feedback, auth/me, GET course by id, dev/authorize. **Fix:** Add tests for these endpoints (happy path and key negative cases).

**Status:** Fixed. `integration-gaps.test.ts` covers `/auth/me`, `/auth/logout`, `GET /courses/:courseId`, `GET /entries/:entryId/feedback`. `edge-cases.test.ts` covers submit (state transitions, empty/boundary inputs, conflict). `acl.test.ts` covers submit authorization. `dev-auth.test.ts` and `dev-auth-localonly.test.ts` cover dev/authorize.

**Sources:** `server/tests/integration-gaps.test.ts`, `server/tests/edge-cases.test.ts`, `server/tests/acl.test.ts`, `server/tests/dev-auth.test.ts`

---

### 47. [Bug] ACL tests miss global-role vs course-role and artifact IDOR cases — ✅ Fixed

**Description:** Tests do not cover teacher-in-course-as-student IDOR or artifact confirm/presign as non-owner. **Fix:** Add tests for role mismatch and artifact ownership.

**Status:** Fixed. `acl.test.ts` includes a test for "uses course role (not global role) for submit authorization" with a user who has global role teacher but course role student. Artifact creation tests cover ownership enforcement on submitted/reviewed entries. Owner-only artifact authorization tests exist in `dev-auth-localonly.test.ts`.

**Sources:** `server/tests/acl.test.ts`, `server/tests/dev-auth-localonly.test.ts`

---

## Remediation Update (February 27, 2026)

The following high-priority items were implemented:

- Dev auth hardened to localhost-only access (`DEV_AUTH_LOCAL_ONLY` outside loopback).
- Artifact `presign`/`confirm` restricted to owning student only.
- Entry submit authorization switched to `roleInCourse` instead of `globalRole`.
- Presign contract extended with `requiredHeaders` and iOS uploader now applies those headers.
- `CORS_ORIGINS` empty state changed to fail-closed.
- `POST /courses/:courseId/entries` now validates `notes` as `string|null`.
- `.env.example` and test setup now use 32+ char JWT secrets.
- Test DB safety tightened: tests refuse to run unless `DATABASE_URL` clearly points to a test DB.
- Added regression tests for localhost-only dev auth, owner-only artifact authorization, and course-role submit logic.

---

## Quick reference: common failure causes

| Symptom | Typical cause | Status |
|--------|----------------|--------|
| 401 on API calls | Missing/invalid token, refresh race | ✅ Fixed: single-flight refresh (#15), Keychain logging (#8) |
| Unexpected sign-out | Refresh race, Keychain write failure | ✅ Fixed: single-flight refresh (#15), Keychain OSStatus logging |
| Teacher sees all entries (incl. drafts) | No status filter on GET entries | ✅ Fixed: defaults to `submitted` (#6) |
| Student can confirm others' artifacts | No ownership check on confirm | ✅ Fixed: `requireStudentOwner` (#10, #17) |
| Entry delete leaves orphaned data / broken storage | Prefetch outside transaction (S3 ordering now fixed) | ✅ Fixed (#5, #20) |
| Upload "succeeds" but artifact not uploaded | Presign URL invalid or no Content-Type | ✅ Fixed: `requiredHeaders` returned and applied (#21) |
| Sync queue item disappears, no error | Parse failure or unknown type treated as success | ✅ Fixed: throws `SyncError` (#22) |
| createEntry fails on iOS (encoding) | Optional.none in JSON body | ✅ Fixed: typed Encodable struct (#27) |
| Decode failure on entries/feedback (iOS) | Date format (fractional seconds) | ✅ Fixed: custom date decoder (#28) |
| Tests wipe real DB | DATABASE_URL not forced to test DB | ✅ Fixed: `test` marker required (#14, #23) |
| Dev auth in production | AUTH_MODE=dev in reachable env | ✅ Mitigated: localhost-only guard + callback URL validation + docs (#1, #3, #30) |

---

## Using this list for issues

- **Labels:** `bug`, `enhancement`, `documentation`, `operational`, `security` as appropriate.
- **Title:** Use the [Bug] / [Enhancement] bracket prefix from the section header.
- **Body:** Copy the relevant section (description, impact, fix, sources) into the issue.
- The **quick reference** table can be linked from the README or a meta-issue for troubleshooting.

### 48. [Bug] Artifact creation allowed on submitted/reviewed entries (state machine violation) — ✅ Fixed

**Description:** `POST /entries/:entryId/artifacts` did not check `entry.status`. A student could add new artifacts to an entry that was already `submitted` or `reviewed`, bypassing the entry lock. The PATCH endpoint correctly blocked edits to non-draft entries, and the submit endpoint required draft status, but artifact creation was missing the same guard.

**Impact:** Data integrity violation — artifacts could be added after teacher review, changing the entry's content post-review without re-triggering the review workflow.

**Fix:** Added a status check in the artifact creation route: if `entry.status !== 'draft'`, the request is rejected with 409 `ENTRY_LOCKED`. Added regression tests for submitted, reviewed, and draft entry artifact creation.

**Sources:** `server/src/routes/artifacts.ts`, `server/tests/acl.test.ts`

---

## 2026-02-27 Masterplan Execution (P0-P2 focus)

### Fixed
- Added `reviewed` to entry lifecycle (`draft -> submitted -> reviewed`) in server Prisma schema and iOS model.
- `POST /feedback` now marks parent entry as `reviewed` for both `targetType=entry` and `targetType=artifact`.
- `GET /courses/:courseId/review-queue` is now deterministic (`practiceDate desc`, `createdAt desc`).
- iOS shows entry status badges and artifact sync phases (`queued`, `uploading`, `confirming`, `uploaded`, `failed`).
- iOS delete flow now requires explicit user confirmation.
- iOS login/settings now display active API host/environment details.
- iOS deep links now refresh courses before navigating if the target course is not yet local.
- Added sync queue UX: pending/failed counters, queue screen, manual retry for failed items.
- Added local student entry templates and teacher feedback snippets.
- Added export-time local practice stats (duration + status distribution).
- Added workspace cleanup script (`scripts/clean-workspace.sh`) and build-artifact guard (`scripts/check-no-build-artifacts.sh`).
- Added docs index and archived legacy docs under `docs/archive/`.

### Remaining / Follow-up
- Full structural dedup split of `SyncManager` into dedicated components (`QueueStore`, `TaskExecutor`, `RetryPolicy`) is still pending.
- Full server-wide parser/authz dedup into service+policy layers remains partially complete.
