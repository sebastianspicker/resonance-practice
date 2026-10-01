# Architecture

Resonance pairs one offline-first SwiftUI client with one Fastify/Prisma server
monolith. PostgreSQL holds application state, and S3-compatible storage holds
protected media. Running that stack in production is an operator task; this
repository provides the source and a disposable local setup.

At a glance:

- **Client.** One SwiftUI app for iPhone and iPad (`ios/ResonanceApp/`),
  organized into `App`, `Core`, `Features`, and `SharedUI`.
- **Server.** One Fastify/Prisma process (`server/`), split into `app`,
  `platform`, and six feature modules.
- **Data.** PostgreSQL for application state, S3-compatible storage for
  protected media; media bytes never pass through the sync endpoint.
- **Contract.** `contracts/v1-api-contract.json` carries the shared v1 wire
  vocabulary, and every resource mutation goes through
  `POST /api/v1/sync/commands`.

## System context

```mermaid
flowchart LR
    Students[Students] --> Client[iOS and iPadOS client]
    Teachers[Teachers] --> Client
    Client -->|Bearer-authenticated HTTP| Server[Fastify server monolith]
    Server --> PostgreSQL[(PostgreSQL)]
    Server --> Storage[(S3-compatible storage)]
    Server -->|OIDC authorization code flow| Provider[OIDC provider]
    Walkthrough[Static walkthrough] -. simulated presentation only .-> Students
```

The client is the only product interface in this repository. The server is one
independently runnable process, not a set of microservices. `demo/site/` is
built and published on its own and has no runtime connection to the client,
server, or data stores.

## Server

`server/src/server.ts` exports `buildServer(prisma, s3)`, which both the process
entry point and the tests use. `server/src/app/` owns the process lifecycle
(`index.ts`: connections, listening, shutdown; `maintenance.ts`: the ordered
background jobs) and the
Fastify assembly (`serverRuntime.ts`: transport policy, readiness, route
registration). `server/src/platform/` holds code no feature owns:
configuration, the HTTP error, input, pagination, and authenticated-request
contracts, deadlines, PostgreSQL advisory locks, and the S3 adapter.

| Module | Owns |
| --- | --- |
| `identity` | Development login, OIDC, native PKCE code exchange, token sessions, issuer-scoped identity mapping, and the bearer-token `preHandler`. |
| `courses` | Course membership lookups, course-role authorization, and course lists. |
| `entries` | The practice-entry aggregate: entry commands and their rules (create, update, capture markers, submit), optimistic versions, entry locks, visibility and ownership, list and detail reads, and removal of the entry row. |
| `media` | Artifacts and their storage lifecycle: upload sessions, quotas, completion claims, container validation, download sessions, storage-deletion scheduling, and cleanup jobs. |
| `reviews` | Feedback: the create-feedback command and its rules, feedback reads, the review queue, and feedback removal. |
| `sync` | The v1 command gateway: envelope parsing, admission limits, durable receipts and replay, dispatch to the owning module, and mapping outcomes to sync results. |

Each module splits an `http/` adapter from an `application/` boundary. HTTP code
parses transport input and maps responses; application code owns rules,
authorization, and transactions. Commands throw `ApiError`s; a stale
`baseVersion` throws `EntryVersionConflictError`, which sync reports as a
`conflict` result carrying the current entry.

The feature dependency graph is acyclic and only reaches into `application/`:

| Module | May use |
| --- | --- |
| `identity`, `courses` | no other module |
| `entries` | `courses` |
| `media` | `entries` |
| `reviews` | `courses`, `entries` |
| `sync` | `courses`, `entries`, `media`, `reviews` |

Sync dispatches each command to its owning module and composes the one use case
that spans modules. Deleting an entry runs, in one
transaction: lock and authorize the entry, queue its media for storage deletion
(media), delete feedback targeting it (reviews), then delete the entry and keep a
tombstone (entries). `platform` never imports modules or `app`.
`server/tests/module-dependency-rules.test.ts` enforces these rules, plus route
ownership per module and the single authenticated-request type. The rules
govern imports; artifact, feedback, and marker rows are children of the entry in
the database, so entry and review rules may read them inside the entry lock
(for example, submission requires uploaded artifacts) while their lifecycle
stays with the owning module. Sync's `entryResource` is the command-result
projection of an entry, deliberately without artifacts; entry reads use
`entries/application/dto.ts`.

## Client

The SwiftUI target is organized under `ios/ResonanceApp/Sources/`:

| Directory | Responsibility |
| --- | --- |
| `App` | Composition (`AppState`), navigation, and the demo and screenshot wiring. |
| `Core` | Domain models, persistence and the local-profile lifecycle, networking, security, media, calendar, export, and synchronization. No SwiftUI; UIKit only as platform adapters (background tasks, the web-auth presentation anchor, PDF rendering). |
| `Features` | Course, capture, entry, export, feedback, review, authentication, settings, and sync-status workflows, plus the environment they need from App (`FeatureEnvironment.swift`). |
| `SharedUI` | Reusable theme and presentation primitives. |

Core depends on nothing above it; SharedUI may use Core; Features may use Core
and SharedUI; only App sees everything. App injects services into features
through the SwiftUI environment (`ErrorReporter`, `apiClient`,
`capturePresentation`) rather than features reaching into App.
`scripts/check-ios-layers.mjs` derives each layer's declared types and rejects
any reference against this direction; it runs in `verify-repository.sh` and
`verify-ios.sh`. Screenshot capture code compiles only with the
`RESONANCE_SCREENSHOTS` condition and demo-data loading only in Debug or
capture builds, so Release builds contain neither. The durable Core outbox
holds typed, versioned commands bound to the authenticated local owner.

## Principal runtime flows

```mermaid
flowchart LR
    UI[Feature UI] --> Local[(SwiftData and protected local files)]
    UI --> Outbox[Typed owner-bound outbox]
    Outbox --> Sync[SyncManager FIFO batches]
    Sync --> Commands[POST /api/v1/sync/commands]
    Commands --> Modules[Server application modules]
    Modules --> Database[(PostgreSQL)]

    Local --> Session[Create artifact session]
    Session --> Upload[Signed PUT to S3]
    Upload --> Complete[Complete artifact session]
    Complete --> Modules
```

Normal resource changes are written to the device first and queued as typed
commands. `SyncManager` serializes ready work, sends at most 25 commands per
request, and preserves operation IDs and optimistic versions across retries.
The server executes a request in order under user- and operation-scoped
admission, persists a durable receipt, and rejects reuse of an operation ID for
different work.

Media bytes never pass through the sync endpoint. The client creates an owner-
and entry-bound upload session, uploads directly with its signed S3 capability,
and asks the server to complete the session. An artifact is published only after
storage metadata and bounded container evidence have been verified.

Completion shares one storage deadline across metadata, cached container probes,
and the final copy, and its database claim outlives that deadline. Background
storage deletion claims one job at a time with an expiring, token-bound lease;
revoked-token retention also runs in bounded background batches.

Course reconciliation consumes entry pages incrementally. Review queues return
marker counts with entry summaries, while entry detail keeps the complete marker
projection. Feedback uses an ascending `(createdAt, id)` cursor and the same
bounded page envelope as entry lists.

## HTTP contracts

`/health` and `/ready` are unversioned operational endpoints, `/auth/*` is an
unversioned authentication boundary, and resource reads and media sessions are
versioned under `/api/v1`.

All externally initiated resource mutations go through one endpoint:

```text
POST /api/v1/sync/commands
```

A request carries one to 25 typed commands. Each command includes an operation
ID, entity ID, kind, payload, and, where required, an optimistic base version.
The server runs commands in request order and persists a user-bound receipt.
Retries with the same operation and payload return the durable outcome;
reusing an operation ID for different work is rejected. Conflict results never
silently overwrite newer server state.

Artifact session creation, completion, and protected download-session creation
stay as versioned media operations because they issue or finalize scoped storage
capabilities. They are not a substitute for entry or feedback mutations.
Creation binds the requested artifact type, byte length, and padded-base64
SHA-256 checksum into the signed upload contract. Completion rechecks those
signed properties and reads bounded ISO-BMFF probes for a permitted M4A or MP4
brand and the expected audio or video track before publication.

There are no legacy unversioned resource-mutation routes. Extend the typed sync
command contract instead of adding resource-specific ones.

## Identity and persistence

Prisma owns PostgreSQL access. `ExternalIdentity` maps an `(issuer, subject)`
pair to a stable internal user, so an OIDC subject is never assumed globally
unique. The additive migration that introduces it also adds hashed browser-
binding, nonce, and PKCE verifier fields to persisted OIDC attempts. Existing
internal user IDs remain valid.

OIDC and internal app codes are short-lived and single-use, and the server
stores hashes of bearer values. Media storage is reached through the platform S3
adapter; application modules enforce ownership, course membership, and consent
before issuing capabilities or returning protected media.

There are two PKCE boundaries. The browser-to-provider attempt keeps its own
state, nonce, browser binding, and verifier. Separately, the native app
generates a verifier, sends its `app_code_challenge` at login, and must present
the matching `codeVerifier` when exchanging the internal code. The `redirectUri`
supplied at exchange must exactly equal `APP_AUTH_REDIRECT_URI`.

For an installed alpha, local persisted data is destructively reset only from the
known predecessor generation. Unknown or incomplete state fails closed and
requires user-directed recovery. This is a client persistence boundary, not an
operator migration procedure.

## Build and deployment boundaries

- The server is a private Node.js package. TypeScript compiles to `server/dist/`,
  and `dist/app/index.js` starts the one server process.
- The iOS app and XCTest bundle build from the tracked Xcode project and shared
  scheme, the only iOS build definition. Its folder-synchronized groups include
  every file under `Sources/` and `Tests/`.
- `contracts/v1-api-contract.json` is the hand-maintained cross-component
  contract. A generated region in the Swift networking contract test projects
  its route and payload vocabulary.
- `infra/docker-compose.yml` supplies disposable loopback development
  dependencies: PostgreSQL and SeaweedFS as the S3-compatible store. The repository has no production server image, infrastructure
  provisioning, application signing, TestFlight, backup, or monitoring workflow.
- `demo/site/` is the only deployed artifact described by repository automation;
  GitHub Pages publishes those static files independently.

Production TLS, secrets, CORS, PostgreSQL, S3, identity-provider operation,
backup, retention, monitoring, and distribution are operator-owned boundaries,
not features implemented here.

## Where new code belongs

- Add an endpoint in the owning module's `http/` directory and add it to the
  route-ownership list in `module-dependency-rules.test.ts`.
- Put business rules, DTOs, authorization, and transactions in the owning
  module's `application/` directory. A new resource mutation is a new sync
  command kind whose handler lives in the owning module; sync only dispatches
  it and maps its outcome.
- Put Fastify-wide behavior, configuration, errors, deadlines, locks, and
  storage adapters in `platform/`. Keep advisory-lock namespaces in
  `platform/database/advisoryLocks.ts`; their values are persisted lock keys.
- Put iOS workflow UI in `Features`, reusable domain rules, transport, persistence,
  and sync in `Core`, generic visuals in `SharedUI`, and composition,
  navigation, demo, and screenshot wiring in `App`.
- Update [API](./API.md), tests, and Swift transport/outbox models when a public
  contract changes.

## Extension rules and non-goals

- Extend the existing owning module rather than adding a second composition root
  or another deployable service.
- Add resource mutation behavior as a typed sync command. Media capability
  creation and completion stay separate because the client transfers bytes
  directly to storage.
- Treat the static walkthrough as presentation, not as product evidence or a
  test client.
- A SAML-only institution needs an external SAML-to-OIDC bridge; this repository
  implements OIDC, not SAML.

Component setup and verification live in the [server README](../server/README.md),
[iOS README](../ios/ResonanceApp/README.md), and
[development guide](./DEVELOPMENT.md).
