# Resonance server

The server is Resonance's private Node.js component. It exposes the HTTP API,
authenticates users, enforces course and entry access, persists application state
through Prisma/PostgreSQL, and coordinates protected media with S3-compatible
storage. It builds and runs as one Fastify monolith and is not published as a
library.

## Requirements

- Node.js 24.x and npm 10 or later
- PostgreSQL
- S3-compatible object storage

The repository Compose file supplies disposable loopback PostgreSQL and SeaweedFS (S3)
for development. It is not a production deployment.

## Setup and run

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

The watcher runs `src/app/index.ts`. For a production-style local start:

```bash
cd server
npm run build
npm run start
```

`npm run build` deletes and recreates `dist/`, and `npm run start` executes
`dist/app/index.js`.

## Configuration

Outside test mode, the server loads `.env` from its working directory without
overwriting variables already set in `process.env`. Start from
[`.env.example`](.env.example) and never commit the copied `.env`.

| Area | Variables |
| --- | --- |
| Process | `NODE_ENV`, `AUTH_MODE`, `HOST`, `PORT`, `DEPENDENCY_TIMEOUT_MS` |
| PostgreSQL | `DATABASE_URL` |
| Sessions | `JWT_SECRET`, `JWT_REFRESH_SECRET`, `ACCESS_TOKEN_TTL_MINUTES`, `REFRESH_TOKEN_TTL_DAYS` |
| Native callback | `APP_AUTH_REDIRECT_URI` |
| Development login | `DEV_UNIVERSITY_NAME`, `DEV_LOGIN_CALLBACK_URL` |
| Browser access | `CORS_ORIGINS` |
| Object storage | `S3_ENDPOINT`, `S3_REGION`, `S3_BUCKET`, `S3_ACCESS_KEY`, `S3_SECRET_KEY`, `S3_FORCE_PATH_STYLE`, `S3_PRESIGN_TTL_SECONDS` |
| Production OIDC | `OIDC_DISCOVERY_URL`, `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`, `OIDC_REDIRECT_URI`, `OIDC_ROLE_CLAIM`, `OIDC_TEACHER_VALUE` |

Development mode defaults to `127.0.0.1` and rejects a non-loopback listener.
Production requires an explicit host, a non-empty CORS allowlist, complete OIDC
settings, and HTTPS for non-loopback OIDC and S3 endpoints. Production access
and refresh signing secrets must be distinct, non-placeholder base64 or
base64url values that each decode to at least 32 bytes.

`OIDC_REDIRECT_URI` is the browser identity-provider callback, and
`APP_AUTH_REDIRECT_URI` is the native application callback. The current iOS
client accepts only `resonance://auth-callback`, so keep the server value aligned
exactly. See [OIDC integration](../docs/SSO_BRIDGE.md).

## Runtime behavior

`src/server.ts` exports `buildServer(prisma, s3)`, shared by the process entry
point and the tests. `src/app/index.ts` owns PostgreSQL and S3 startup,
listening, graceful shutdown, and the maintenance timer; `src/app/maintenance.ts`
lists the maintenance jobs and runs them in order without overlapping passes.
`src/app/serverRuntime.ts` owns transport policy, health/readiness, and route
registration; bearer authentication comes from the identity module.

- `GET /health` reports process liveness.
- `GET /ready` checks PostgreSQL and the configured S3 bucket and returns `503`
  when either dependency is unavailable.
- Maintenance runs at startup and every minute to expire stale uploads, prune
  retained sessions, retry durable storage deletions, and remove sync receipts
  older than 7 days and revoked refresh tokens older than 30 days. Token retention runs in bounded
  batches outside authentication requests.

Storage deletion workers claim one job immediately before contacting S3 and
settle it conditionally using the claim token. Expired claims allow recovery
after a process failure. The additive optimization migration supplies these
claim fields and supporting maintenance indexes; apply it before starting the
updated server. During rollout, stop older workers before starting leased
workers, because the older code does not respect claims.

Active-entry pagination uses two partial indexes maintained in SQL migrations
because Prisma 5 does not express partial indexes. Preserve them when changing
the schema; their owning predicates and sort order live in the entries
application queries.

Production TLS, secret management, backups, restore testing, retention,
monitoring, alerting, database and storage lifecycle, and identity-provider
operation are external responsibilities. See the
[security model](../docs/SECURITY.md).

## Architecture and API

Feature modules live under `src/modules/` and split `http/` transport from
`application/` rules and transactions. Platform-wide configuration, errors,
deadlines, and storage adapters live under `src/platform/`. The
[architecture guide](../docs/ARCHITECTURE.md) covers the dependency rules and
data flows; the [API reference](../docs/API.md) documents the routes and command
shapes.

The canonical route and wire vocabulary is
`../contracts/v1-api-contract.json`. Resource changes go through
`POST /api/v1/sync/commands`, while the media POST routes create or finalize
scoped storage capabilities.

## Commands

Run these from `server/`:

| Purpose | Command |
| --- | --- |
| Watch development server | `npm run dev` |
| Type-check sources, seeds, and benchmarks | `npm run typecheck` |
| Build `dist/` from `src/` | `npm run build` |
| Measure synthetic read projections and query plans | `npm run benchmark:reads` |
| Validate the contract document | `npm run verify:contracts` |
| Run ESLint, Knip, and duplication checks | `npm run quality` |
| Check formatting | `npm run format:check` |
| Generate Prisma client | `npm run prisma:generate` |
| Apply committed migrations | `npm run prisma:migrate` |

Tests use a real `resonance_test` PostgreSQL database and mocked S3. Follow the
test-database and reset safeguards in [Development](../docs/DEVELOPMENT.md).
