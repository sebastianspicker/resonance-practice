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

Compose starts loopback-only PostgreSQL and SeaweedFS, an S3-compatible store
on port 9000 that enforces the development credentials. The development server
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

The bootstrap validates the fixture, starts PostgreSQL and S3 storage and waits
for both to report healthy, installs server dependencies, applies migrations,
and seeds mock records. API readiness is reported only when the API is already
running. In the
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
| Pure repository checks | `./scripts/verify-repository.sh` | Checks Node version, the v1 contract, fixtures, static demo, Markdown links and images, secrets, and committed build artifacts. |
| Server type-check | `cd server && npm run typecheck` | Checks `src`, `prisma`, and `benchmarks` without emitting. |
| Server build | `cd server && npm run build` | Removes and recreates generated `server/dist/` from `src`. |
| Server lint and quality | `cd server && npm run quality` | Runs ESLint, Knip, and cross-language duplication checks. |
| Server format check | `cd server && npm run format:check` | Run `npm run format` only when you intend to rewrite TypeScript formatting. |
| Swift lint | `./scripts/lint-swift.sh lint` | Requires SwiftLint 0.63.2. |
| Swift analysis | `./scripts/lint-swift.sh analyze` | Builds with the legacy Swift driver, then runs the unused-declaration and unused-import analyzer rules; fails if no files were analyzed. |
| iOS build | `./scripts/verify-ios.sh` | Runs the source-layer check, a Debug build through the shared scheme, and Release and screenshot-capture builds. |
| Public Markdown links and images | `node scripts/validate-public-docs.mjs` | Checks repository containment, existence, and publication eligibility. Images need alt text. |
| Full local CI | `./scripts/ci-local.sh --with-docker` | Provisions disposable services, runs the server and iOS lanes, and stops Compose on exit. |

`./scripts/ci-local.sh` without `--with-docker` still needs a running Docker
daemon for Compose validation, ShellCheck, and actionlint, but expects
PostgreSQL and S3 storage to be supplied separately.

The full lane exports local-only defaults for the required server configuration,
including two distinct JWT secrets; values already set in the process
environment take precedence, and `server/.env` never overrides them.

The iOS verifier supports:

- `IOS_DESTINATION` to select a simulator destination;
- `IOS_TOOLCHAIN` and `IOS_EXPECTED_SWIFT_VERSION` for an alternate toolchain;
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
does not truncate existing tables.

The JSON output records the runtime, fixture size and timestamp, three warmup
runs, twenty alternating measured runs, minimum/median/p95/maximum milliseconds,
serialized response bytes, and PostgreSQL student/review query plans. It
compares the full entry projection with the review summary on the same data.
Query-plan output is evidence for the current schema, not a measurement of the
previous one. The transactional fixture uses existing table statistics, so
planner estimates may not reflect its synthetic distribution. Capture comparable
runs before and after index changes on the same PostgreSQL version and machine;
realistic deployment data can produce different plans.

Use Instruments on a device for UI hitches, peak memory, and energy during multi-minute media
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
AUTH_MODE=dev \
DATABASE_URL=postgresql://resonance:resonance@localhost:5432/resonance \
RESONANCE_CONFIRM_DEV_DB_RESET=RESET_DEVELOPMENT_DATABASE npm run db:reset
```

All three values must be in the process environment; the guard does not read
`server/.env`.

It refuses any mode except `AUTH_MODE=dev` and any database other than a loopback
`resonance` database using the `public` schema. Demo reset and test database
cleanup have their own guards.

## Generated and local paths

Do not commit `server/.env`, dependencies, `server/dist/`, SwiftPM or
DerivedData output, coverage reports, Compose volumes, analyzer indexes, test
results, or local screenshots.

`contracts/v1-api-contract.json` is hand-maintained. Verify it with
`./scripts/verify-repository.sh`.
