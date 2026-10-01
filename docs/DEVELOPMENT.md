# Development

This guide is the source of truth for local setup, fixtures, tests, and
repository-wide validation. Component-specific configuration and commands live
in the [server](../server/README.md) and [iOS](../ios/ResonanceApp/README.md)
READMEs.

## Prerequisites

The repository pins Node.js 24 in `.nvmrc`; the server requires npm 10 or later.
Local services need Docker with Docker Compose.

iOS work needs macOS, Xcode with the iOS 17 SDK or later, `xcrun`, `xcodebuild`,
`jq`, and an available iPhone Simulator. Strict Swift linting needs SwiftLint
0.63.2, and the full local CI lane also verifies with the exact Swift 6.3.3
toolchain.

## Start the server and client

From the repository root:

```bash
cp server/.env.example server/.env
docker compose -f infra/docker-compose.yml up -d

cd server
npm ci
npm run prisma:generate
npm run prisma:migrate
npm run prisma:seed
npm run dev
```

Compose starts loopback-only PostgreSQL and MinIO. The development server
defaults to `127.0.0.1:4000`; `GET /health` checks process liveness and
`GET /ready` checks PostgreSQL and S3 availability.

Open `ios/ResonanceApp/ResonanceApp.xcodeproj` and run the shared `ResonanceApp`
scheme. To point a development launch at another credential-free HTTP(S) origin,
set `RESONANCE_API_BASE` in the scheme environment; invalid values fall back to
`http://localhost:4000`. The native callback is fixed at
`resonance://auth-callback`, so the server's `APP_AUTH_REDIRECT_URI` must match
it exactly.

The alpha baseline migration assumes a disposable rebuild of databases from
older alpha generations. It is not an in-place production upgrade.

## Local demo data

The demo uses deterministic synthetic records and must not contain real student
data or private recordings.

From the repository root, with Docker running:

```bash
./scripts/demo/bootstrap-local-demo.sh
node scripts/demo/validate-fixture.mjs
```

The bootstrap validates the fixture, starts PostgreSQL and MinIO, installs
server dependencies, applies migrations, and seeds mock records. It verifies
MinIO; API readiness is reported only when the API is already running. In the
app, sign in through development login and use **Settings > Debug > Load Mock
Demo Data**.

To remove only the guarded `demo_*` records from the loopback `resonance`
database:

```bash
./scripts/demo/reset-local-demo.sh
```

## Validation

Run commands from the repository root unless the command changes directory.

| Scope | Command | Notes |
| --- | --- | --- |
| Pure repository checks | `./scripts/verify-repository.sh` | Checks Node version, the v1 contract and generated projection, fixtures, static demo, Markdown links and images, secrets, and committed build artifacts. |
| Server build/type-check | `cd server && npm run build` | Removes and recreates generated `server/dist/`. |
| Server tests | `cd server && npm test` | Uses Vitest with real Prisma/PostgreSQL and mocked S3. |
| Server contract tests | `cd server && npm run test:contracts` | Checks the v1 route contract and module dependency rules. |
| Server lint and quality | `cd server && npm run quality` | Runs ESLint, Knip, and cross-language duplication checks. |
| Server format check | `cd server && npm run format:check` | Run `npm run format` only when you intend to rewrite TypeScript formatting. |
| Swift lint | `./scripts/lint-swift.sh lint` | Requires SwiftLint 0.63.2. |
| iOS build and test | `./scripts/verify-ios.sh` | Runs the layering guard and XCTest through the shared Xcode scheme. |
| Public Markdown links and images | `node scripts/validate-public-docs.mjs` | Checks repository containment, existence, and publication eligibility. Images need alt text. |
| Full local CI | `./scripts/ci-local.sh --with-docker` | Provisions disposable services, runs the server and iOS lanes, and stops Compose on exit. |

`./scripts/ci-local.sh` without `--with-docker` still needs a running Docker
daemon for Compose validation, ShellCheck, and actionlint, but expects
PostgreSQL and MinIO to be supplied separately.

The full lane reads the required server configuration from the process
environment or from the valid `server/.env` created during setup, including both
distinct JWT secrets. A direct `cd server && npm test` is a focused rerun: it
expects the guarded `resonance_test` database to exist with current migrations
already applied.

The iOS verifier supports:

- `IOS_DESTINATION` to select a simulator destination;
- `IOS_TOOLCHAIN` and `IOS_EXPECTED_SWIFT_VERSION` for an alternate toolchain;
- `IOS_RESULT_BUNDLE_PATH` to retain an XCTest result bundle at a new path;
- `IOS_DERIVED_DATA_PATH` to reuse a local build directory on focused reruns.
  Use a separate directory for each Xcode version and Swift toolchain. This
  CI keeps clean build directories.

GitHub CI runs the bundled and exact Swift compiler lanes as independent jobs.
The aggregate `iOS Build` check succeeds only when both pass. Server test files
run serially because their fixtures truncate a shared test database.

## Performance checks

Run `npm run benchmark:reads` from `server/` with `DATABASE_URL` pointed
explicitly at the guarded loopback `resonance_test` database after migrations.
The benchmark inserts 10,000 synthetic entries and 50 capture markers per
first-page entry inside a transaction, then rolls the whole fixture back. It
does not truncate existing tables. Run it separately from the test suite, which
does truncate shared test fixtures.

The JSON output records the runtime, fixture size and timestamp, three warmup
runs, twenty alternating measured runs, minimum/median/p95/maximum milliseconds,
serialized response bytes, and PostgreSQL student/review query plans. It
compares the full entry projection with the review summary on the same data.
Query-plan output is evidence for the current schema, not a measurement of the
previous one. The transactional fixture uses existing table statistics, so
planner estimates may not reflect its synthetic distribution. Capture comparable
runs before and after index changes on the same PostgreSQL version and machine;
realistic deployment data can produce different plans.

Focused media tests exercise delayed response bodies, the complete validation
budget, and range-request counts for synthetic containers. iOS tests cover large
outbox selection, paged reconciliation, cancellation, and file preparation.
Retain XCTest results with `IOS_RESULT_BUNDLE_PATH`, and use Instruments on a
device for UI hitches, peak memory, and energy during multi-minute media
workflows. Host-side functional checks do not establish device latency or
battery gains.

## Test database safety

Server tests use `resonance_test` with the `public` schema and may clear its
tables. The full local CI script validates the target, creates the local test
database when needed, and applies migrations before running tests. Never aim
`DATABASE_URL` at development, shared, or production data.

The separate development reset is deliberately destructive:

```bash
cd server
RESONANCE_CONFIRM_DEV_DB_RESET=RESET_DEVELOPMENT_DATABASE npm run db:reset
```

It refuses any mode except `AUTH_MODE=dev` and any database other than a loopback
`resonance` database using the `public` schema. Demo reset and test database
cleanup have their own guards.

## Generated and local paths

Do not commit `server/.env`, dependencies, `server/dist/`, SwiftPM or
DerivedData output, coverage reports, Compose volumes, analyzer indexes, test
results, or local screenshots.

`contracts/v1-api-contract.json` is hand-maintained, and the marked projection in
`ios/ResonanceApp/Tests/NetworkingContracts/APIClientSyncCommandTests.swift` is
generated. Verify it with `./scripts/verify-repository.sh` and update it only
after an intentional contract change:

```bash
node scripts/generate-v1-contract-projection.mjs --write
```
