# Resonance

Resonance is an offline-first iOS and iPadOS application for practice evidence
and private teacher feedback in music education. Students create practice or
teaching-lesson entries, attach audio or consented video, submit entries to a
course, and receive timestamped feedback. Teachers review submitted entries
within their course memberships.

[Open the static product walkthrough](https://sebastianspicker.github.io/resonance/).
It uses sanitized fixture data and the app's visual system. Every command-capable
action is marked as simulated, and the page does not connect to the API or store data.

The repository contains a native SwiftUI client, a Fastify API, a PostgreSQL
schema, and local development infrastructure. The current
`v0.1.0-alpha.1` candidate is source-only. It does not include a signed app,
TestFlight distribution, hosted service, or production infrastructure.

## Current capabilities

- SwiftUI client targeting iOS and iPadOS 17 or later.
- SwiftData persistence for courses, entries, artifacts, feedback, calendar
  data, and a durable synchronization queue.
- Offline entry creation and queued synchronization with retry, deduplication,
  account ownership checks, and optimistic versions.
- Practice audio and consented teaching-lesson video with manual markers.
- Student entry submission and teacher review with structured, timestamped
  feedback.
- Fastify API with development authentication, configurable OpenID Connect
  authentication, course authorization, and consistent error responses.
- PostgreSQL persistence through Prisma.
- S3-compatible artifact upload sessions, protected downloads, and deferred
  object deletion.
- Deterministic local fixtures, server tests, iOS XCTest, linting, formatting,
  dead-code checks, duplicate checks, and CI workflows.

## Limitations

- The interface is currently English-only.
- The full accessibility, Dynamic Type, keyboard, device-layout, localization,
  poor-network, and performance matrices have not been completed.
- Some capture editing, preview, retake, reviewed-history, Calendar, Export,
  Settings, and Sync states need further product validation.
- No live university identity provider, production PostgreSQL service, object
  store, backup process, retention process, signing workflow, or deployment has
  been validated by this repository.
- The local MinIO service is for loopback development and CI only.
- No approved public screenshot set currently exists.

## Local setup

Backend and repository checks require:

- Node.js 24.x, as specified by [`.nvmrc`](.nvmrc).
- npm 10 or later.
- Docker with Compose for the local PostgreSQL and MinIO services. No exact
  Docker or Compose version is pinned.

iOS development and the complete local verification path additionally require:

- macOS with Xcode 26 and an iOS 17-or-later Simulator runtime. CI uses a
  macOS 26 runner; no Xcode minor version is pinned.
- `jq`, used by the simulator selection script.
- SwiftLint 0.63.2.
- Swift 6.3.3 for the second compiler gate. The Xcode-bundled compiler is
  checked separately.

## Installation

From the repository root:

```bash
cp server/.env.example server/.env
```

Before starting services, edit `server/.env`, set `AUTH_MODE=dev`, and verify
the required database, JWT, and S3 values. Then run:

```bash
docker compose -f infra/docker-compose.yml up -d

cd server
npm ci
npm run prisma:generate
npm run prisma:migrate
npm run prisma:seed
```

The repository has one Prisma migration,
`server/prisma/migrations/20260716000000_alpha_baseline`. A database created
from an earlier alpha migration chain must be backed up if needed and rebuilt
before applying this baseline. Do not modify Prisma's `_prisma_migrations`
table to bypass the migration history.

## Configuration

For local development, keep the server bound to a loopback address. The server
validates configuration at startup.

Required backend values:

| Variable | Purpose |
| --- | --- |
| `DATABASE_URL` | PostgreSQL connection used by Prisma. |
| `JWT_SECRET` | Access-token signing secret. Must contain at least 32 characters. |
| `S3_ENDPOINT` | S3-compatible service endpoint. |
| `S3_BUCKET` | Artifact bucket name. |
| `S3_ACCESS_KEY` | S3 access key. |
| `S3_SECRET_KEY` | S3 secret key. |

Important optional or mode-specific values:

| Variable | Default or requirement |
| --- | --- |
| `AUTH_MODE` | Defaults to `prod`; set to `dev` only for loopback development. |
| `HOST` | Defaults to `127.0.0.1` in development; required in production. |
| `PORT` | Defaults to `4000`. |
| `JWT_REFRESH_SECRET` | Defaults to a value derived from `JWT_SECRET`; use a separate secret outside local development. |
| `CORS_ORIGINS` | Comma-separated exact origins; at least one is required in production. |
| `OIDC_DISCOVERY_URL` | Required in production. URL passed to `openid-client` discovery. |
| `OIDC_CLIENT_ID` | Required in production. |
| `OIDC_CLIENT_SECRET` | Required in production. |
| `OIDC_REDIRECT_URI` | Required in production. |
| `OIDC_ROLE_CLAIM` | Defaults to `role`. |
| `OIDC_TEACHER_VALUE` | Defaults to `teacher`. |
| `ACCESS_TOKEN_TTL_MINUTES` | Defaults to `15`; must be a positive integer. |
| `REFRESH_TOKEN_TTL_DAYS` | Defaults to `7`; must be a positive integer. |
| `DEPENDENCY_TIMEOUT_MS` | Defaults to `10000`; accepted range is 100 to 300000. |
| `S3_REGION` | Defaults to `us-east-1`. |
| `S3_FORCE_PATH_STYLE` | Defaults to `true`. |
| `S3_PRESIGN_TTL_SECONDS` | Defaults to `900`; accepted range is 1 to 604800. |
| `DEV_UNIVERSITY_NAME` | Label shown by the local development sign-in page. |
| `DEV_LOGIN_CALLBACK_URL` | Defaults to `resonance://auth-callback`. |

The iOS client defaults to `http://localhost:4000`. Set
`RESONANCE_API_BASE` in the Xcode scheme to use another credential-free HTTP
or HTTPS base URL.

## Usage

Start the API:

```bash
cd server
npm run dev
```

Open `ios/ResonanceApp/ResonanceApp.xcodeproj`, select the shared
`ResonanceApp` scheme, and run an iPhone or iPad Simulator. In development
mode, the app opens the loopback sign-in page. Select the student or teacher
persona to create a local session.

To prepare deterministic demo data:

```bash
./scripts/demo/bootstrap-local-demo.sh
```

The fixture can be validated without Docker:

```bash
node scripts/demo/validate-fixture.mjs
```

See [Local demo](docs/LOCAL_DEMO.md) for fixture loading, reset behavior, and
the screenshot capture path.

## Repository structure

| Path | Contents |
| --- | --- |
| `ios/ResonanceApp/` | SwiftUI application, SwiftData models, networking, sync services, resources, Xcode project, and XCTest. |
| `server/src/` | Fastify composition root, routes, authentication, validation, storage, and service logic. |
| `server/prisma/` | Prisma schema, baseline migration, seed commands, and demo reset logic. |
| `server/tests/` | Vitest suites, shared support modules, and process-level E2E tests. |
| `tests/repository/` | Node test suites for repository policy scripts. |
| `infra/` | Loopback-only PostgreSQL and MinIO Compose services. |
| `demo/` | Deterministic mock-university fixture. |
| `scripts/` | Verification, safety, local demo, and screenshot commands. |
| `docs/` | API, architecture, operations, security, product, and release documentation. |
| `.github/` | CI, security analysis, issue forms, and contribution templates. |

## Development workflow

Install dependencies with `npm ci` and keep changes scoped. Use the narrowest
relevant test while editing, then run the broadest available gate.

Common backend commands:

```bash
cd server
npm run build
npm test
npm run lint
npm run format:check
npm run quality:dead-code
npm run quality:duplicates
```

`npm run build` invokes TypeScript with the strict project configuration and
serves as the backend type check. Use `npm run format` only when an intentional
formatting change is in scope.

## Testing

The complete local CI-equivalent command is:

```bash
./scripts/ci-local.sh --with-docker
```

It validates Compose, repository boundaries, fixtures, documentation, shell
script contracts, workflows, backend lint and formatting, dependency audit, Prisma
generation and migration, TypeScript compilation, server readiness, coverage,
process-level E2E behavior, SwiftLint, and iOS XCTest with both supported Swift
compiler paths.

Focused checks:

```bash
# Backend tests. PostgreSQL must be available.
cd server
npm test

# Process-level E2E. PostgreSQL and MinIO must be available.
npm run test:e2e

# iOS build and XCTest on an available Simulator.
cd ..
./scripts/verify-ios.sh
```

The test database safety guard requires the database name
`resonance_test`. See [Development and operations](docs/RUNBOOK.md) for the
exact database setup and tool requirements.

## Deployment and operation

Build and start the API with:

```bash
cd server
npm ci
npm run prisma:generate
npm run build
npm run prisma:migrate
npm run start
```

`GET /health` reports process availability. `GET /ready` checks PostgreSQL and
the configured object-storage bucket and returns HTTP 503 when either
dependency is unavailable.

Production mode requires explicit `HOST`, `CORS_ORIGINS`, OIDC settings,
PostgreSQL, an S3-compatible object store, operator-managed TLS, and secret
injection. The repository supplies no container image, infrastructure
definition, ingress, backup automation, or monitoring configuration for a
production deployment. Treat the sequence above as an application start
contract, not a complete deployment recipe. See
[Development and operations](docs/RUNBOOK.md) and
[OIDC configuration](docs/SSO_BRIDGE.md).

## Troubleshooting

- Startup reports a missing environment variable: compare the active
  environment with the tables above and `server/.env.example`.
- Development authentication returns 403: access the server through
  `localhost`, `127.0.0.1`, or `::1`, and verify `AUTH_MODE=dev`.
- Production startup rejects the host or CORS configuration: set `HOST`
  explicitly and provide at least one exact `CORS_ORIGINS` value.
- `/ready` returns 503: verify PostgreSQL connectivity, the S3 endpoint,
  credentials, bucket, and `DEPENDENCY_TIMEOUT_MS`.
- Prisma rejects a destructive test command: use a database named
  `resonance_test`; demo reset commands require the loopback `resonance`
  database.
- The iOS app contacts the wrong server: check `RESONANCE_API_BASE` in the
  active Xcode scheme.
- iOS verification cannot choose a Simulator: install an iPhone Simulator or
  set `IOS_DESTINATION`.

Additional failure cases are documented in
[Development and operations](docs/RUNBOOK.md).

## Security considerations

- Never commit environment files, credentials, tokens, signed URLs, private
  recordings, or real student data.
- Development authentication is unauthenticated and must remain on loopback.
- Production authentication requires OpenID Connect. No live provider has been
  validated by this repository.
- The API authorizes entry and artifact access through course membership and
  ownership checks.
- Artifact download responses use short-lived signed URLs and
  `Cache-Control: no-store`.
- The iOS app stores session tokens and account ownership state in Keychain and
  protects local media with iOS file protection.
- The Compose credentials and MinIO image are development values. Do not reuse
  them outside a disposable local environment.

Read the [security model](docs/SECURITY.md). Report vulnerabilities through
[GitHub private vulnerability reporting](https://github.com/sebastianspicker/resonance/security/advisories/new).

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a change. Pull requests
should explain behavior, include relevant tests, update affected contracts,
and list any checks that could not be run. Do not include local logs, private
data, build output, or unreviewed screenshots.

The [documentation index](docs/INDEX.md) lists the current technical and
product references.

## License

MIT. See [LICENSE](LICENSE).
