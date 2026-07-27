# Development and operations

This runbook covers the checked-in development and verification paths. The
repository does not contain or validate production infrastructure.

## Prerequisites

- Node.js 24.x and npm 10 or later.
- Docker with Compose. No exact Docker or Compose version is pinned.
- macOS with Xcode 26 and an iOS 17-or-later Simulator runtime for iOS work.
  CI uses a macOS 26 runner; no Xcode minor version is pinned.
- `jq` for deterministic Simulator selection.
- SwiftLint 0.63.2 for Swift linting.
- Swift 6.3.3 for the additional compiler gate used by CI.

Check the active Node runtime:

```bash
node scripts/check-node-version.mjs
```

If Node Version Manager is installed, `.nvmrc` can select the repository
runtime:

```bash
nvm use
```

Install SwiftLint through the same package source used by CI and confirm the
exact version:

```bash
brew install swiftlint
test "$(swiftlint version)" = "0.63.2"
```

## Local configuration

Create the ignored backend environment file:

```bash
cp server/.env.example server/.env
```

Set `AUTH_MODE=dev` for local sign-in. Development mode defaults `HOST` to
`127.0.0.1` and rejects explicit non-loopback hosts. The `/dev/login`,
`/dev/authorize`, and `/dev/issue` routes do not require credentials and must
not be exposed to a network.

The server configuration reference is in the
[README](../README.md#configuration). Production authentication settings are
documented in [OIDC configuration](./SSO_BRIDGE.md).

## Local services

Start PostgreSQL and MinIO:

```bash
docker compose -f infra/docker-compose.yml up -d
```

Inspect their status:

```bash
docker compose -f infra/docker-compose.yml ps
```

Stop the services without deleting their volumes:

```bash
docker compose -f infra/docker-compose.yml down
```

Both services bind to loopback. The Compose credentials and MinIO image are
only for disposable local development and CI.

## Backend setup

```bash
cd server
npm ci
npm run prisma:generate
npm run prisma:migrate
npm run prisma:seed
npm run dev
```

The development process watches TypeScript sources. The API listens on
`http://127.0.0.1:4000` by default.

Build and run the compiled server:

```bash
cd server
npm run build
npm run start
```

`npm run build` runs the strict TypeScript compiler and is the backend type
check.

### Migration baseline

The active migration directory contains one squashed alpha baseline:

```text
server/prisma/migrations/20260716000000_alpha_baseline/
```

This baseline is not an upgrade path from earlier alpha migration chains. Back
up any local data that matters, recreate the database, and then run
`npm run prisma:migrate`. Do not edit Prisma's `_prisma_migrations` table.

## iOS setup

Open:

```text
ios/ResonanceApp/ResonanceApp.xcodeproj
```

Select the shared `ResonanceApp` scheme and an iPhone or iPad Simulator. The
app defaults to `http://localhost:4000`. To use another server, add
`RESONANCE_API_BASE` to the active scheme. The value must be a
credential-free HTTP or HTTPS URL without a query or fragment.

The application target uses Swift language mode 6 and has an iOS 17 deployment
floor. The Swift package manifest is available for source and test discovery,
but the checked-in Xcode project is the supported app build path.

## Local demo

Prepare deterministic fixture data:

```bash
./scripts/demo/bootstrap-local-demo.sh
```

The command validates both fixture copies, starts local services, installs
locked backend dependencies, generates the Prisma client, applies migrations,
and seeds records whose identifiers use the reserved `demo_` prefix.

Reset only those demo records:

```bash
./scripts/demo/reset-local-demo.sh
```

The reset guard accepts only the loopback database named `resonance`. See
[Local demo](./LOCAL_DEMO.md) for the in-app workflow and screenshot capture
path.

## Backend tests

Unit and integration tests require PostgreSQL:

```bash
docker compose -f infra/docker-compose.yml up -d postgres
cd server
npm test
```

The default Vitest configuration excludes `tests/e2e/`. It runs serially and
enforces these V8 coverage thresholds when coverage is enabled:

| Metric | Threshold |
| --- | ---: |
| Statements | 85% |
| Branches | 75% |
| Functions | 90% |
| Lines | 85% |

Run coverage:

```bash
cd server
npm run test:coverage
```

Process-level E2E tests require PostgreSQL and MinIO. The database must be named
`resonance_test`:

```bash
docker compose -f infra/docker-compose.yml up -d
cd server
export DATABASE_URL=postgresql://resonance:resonance@localhost:5432/resonance_test
node ../scripts/assert-test-database-url.mjs
npm run prisma:migrate
npm run test:e2e
```

The E2E suite builds and starts the API on a temporary loopback port and
exercises the student-submission and teacher-feedback flow over HTTP.

## iOS tests

Run the shared Xcode scheme against an available iPhone Simulator:

```bash
./scripts/verify-ios.sh
```

The script creates isolated DerivedData. Set `IOS_DESTINATION` to an explicit
Xcode destination when automatic selection is unsuitable.

CI runs the Xcode-bundled compiler first and Swift 6.3.3 second. Install and
verify the additional toolchain with:

```bash
./scripts/install-swift-toolchain.sh
IOS_TOOLCHAIN=swift IOS_EXPECTED_SWIFT_VERSION=6.3.3 ./scripts/verify-ios.sh
```

## Lint, format, and repository checks

```bash
cd server
npm run lint
npm run format:check
npm run quality:dead-code
npm run quality:duplicates
```

Run Swift lint:

```bash
./scripts/lint-swift.sh lint
```

Additional repository checks:

```bash
node scripts/demo/validate-fixture.mjs
node scripts/validate-public-docs.mjs
node --test tests/repository/*.test.mjs
./scripts/secret-scan.sh
./scripts/check-no-build-artifacts.sh
```

The secret scan intentionally excludes environment-file contents. Environment
files require separate manual review and must remain untracked.

## Complete local gate

Run:

```bash
./scripts/ci-local.sh --with-docker
```

This command:

1. checks the test database target and Node version;
2. starts PostgreSQL and MinIO;
3. validates Compose, fixtures, documentation, repository policy scripts, shell
   scripts, and workflows;
4. scans tracked and nonignored files for secrets and disallowed output;
5. installs locked backend dependencies;
6. runs backend lint, dead-code, duplicate, format, and dependency checks;
7. generates Prisma, applies migrations, compiles TypeScript, and probes
   readiness;
8. runs backend coverage and process E2E tests;
9. runs SwiftLint and iOS XCTest with both compiler paths.

Docker must be running even without `--with-docker` because the script uses
containerized ShellCheck and actionlint. Without `--with-docker`, PostgreSQL
and MinIO must already be available.

## Service probes and shutdown

Process liveness:

```bash
curl -fsS http://127.0.0.1:4000/health
```

Dependency readiness:

```bash
curl -fsS http://127.0.0.1:4000/ready
```

Readiness probes PostgreSQL and the configured S3 bucket within
`DEPENDENCY_TIMEOUT_MS`. It returns HTTP 503 if either check fails.

The server handles `SIGTERM` and `SIGINT`. It stops accepting HTTP traffic,
waits for active storage maintenance, disconnects Prisma, and applies separate
five-second bounds to those shutdown steps. Deferred object-deletion jobs
remain in PostgreSQL for a later process if shutdown interrupts them.

## Local workspace maintenance

Preview removable build and runtime output:

```bash
./scripts/clean-workspace.sh --dry-run
```

Review the list before running:

```bash
./scripts/clean-workspace.sh
```

This operation removes local build output and tool caches. It is not part of
normal application startup.

## Production application contract

The following steps describe the application process only. They do not provide
TLS, ingress, process supervision, database provisioning, object-storage
provisioning, backups, monitoring, or disaster recovery.

Required operator-supplied services:

- PostgreSQL.
- A supported and patched S3-compatible object store.
- OpenID Connect identity provider registration.
- TLS termination and network access controls.
- Runtime secret injection.
- Backup, recovery, retention, and monitoring procedures.

Build and migrate:

```bash
cd server
npm ci
npm run prisma:generate
npm run build
npm run prisma:migrate
```

Start the process:

```bash
npm run start
```

Production mode requires:

```text
AUTH_MODE=prod
HOST=<listener-host-or-address>
CORS_ORIGINS=<comma-separated-exact-origins>
OIDC_DISCOVERY_URL=<issuer-or-discovery-url>
OIDC_CLIENT_ID=<client-id>
OIDC_CLIENT_SECRET=<client-secret>
OIDC_REDIRECT_URI=https://<api-host>/auth/oidc/callback
```

It also requires `DATABASE_URL`, `JWT_SECRET`, and all required `S3_*` values.
Use a separate `JWT_REFRESH_SECRET`. Place the server behind operator-managed
TLS and configure liveness and readiness probes separately.

Do not deploy the Compose credentials or the bundled MinIO image. Validate the
complete operating model in a disposable staging environment before using
private data.

## Troubleshooting

### Node version check fails

Inspect the configured and active versions:

```bash
cat .nvmrc
node --version
```

Activate Node 24.x with the version manager used on the workstation. For
example, with Node Version Manager:

```bash
nvm use
node scripts/check-node-version.mjs
```

### Development sign-in returns 403

Confirm `AUTH_MODE=dev` and access the API through `localhost`, `127.0.0.1`, or
`::1`. A proxy address is not treated as loopback.

### Server exits during configuration loading

Read the exact startup error. Configuration validation rejects missing required
values, short JWT secrets, invalid numeric ranges, a non-loopback development
host, missing production CORS origins, and incomplete production OIDC values.

### Readiness returns 503

Verify the PostgreSQL connection, S3 endpoint, credentials, bucket, and
`DEPENDENCY_TIMEOUT_MS`. `/health` can still return 200 when dependencies are
unavailable.

### Test database guard rejects the URL

Use a PostgreSQL URL whose database name is exactly `resonance_test`. The guard
also rejects non-public schemas and explicit search-path overrides.

### Demo reset refuses to run

The demo guard accepts only a loopback PostgreSQL URL whose database name is
exactly `resonance`.

### iOS verification cannot find a destination

List installed devices and Xcode destinations:

```bash
xcrun simctl list devices available
xcodebuild -showdestinations \
  -project ios/ResonanceApp/ResonanceApp.xcodeproj \
  -scheme ResonanceApp
```

Install an iPhone Simulator runtime if none is available, or pass one of the
reported destinations:

```bash
IOS_DESTINATION='platform=iOS Simulator,id=<simulator-udid>' \
  ./scripts/verify-ios.sh
```

### The app uses the wrong API endpoint

Inspect `RESONANCE_API_BASE` in the active Xcode scheme. Invalid values fall
back to `http://localhost:4000`.

### A different account is blocked from local data

Use the in-app local-data replacement or sign-out action. The app cancels
active sync and deletes the previous account's SwiftData, media, calendar,
feedback, and queue state only after explicit confirmation.
