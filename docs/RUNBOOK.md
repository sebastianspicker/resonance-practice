# RUNBOOK

This runbook captures current local-development and verification commands. The final section lists production deployment requirements; the repository does not supply or validate production infrastructure.

## Prerequisites

- Node.js (recommended: 20.x) + npm
- Docker Desktop (for Postgres + MinIO)
- Xcode (for iOS app work)

## Environment

- Backend env file:
  - `cp server/.env.example server/.env`
- **Dev auth:** Set `AUTH_MODE=dev` only for local development. Never set `AUTH_MODE=dev` in any environment reachable from the network (e.g. staging or production). Dev auth endpoints (`/dev/login`, `/dev/authorize`, `/dev/issue`) are unauthenticated and must remain strictly local-only (e.g. bind to loopback or run only on localhost).

## Local Services

Start Postgres + MinIO:
```bash
docker compose -f infra/docker-compose.yml up -d
```
Stop services:
```bash
docker compose -f infra/docker-compose.yml down
```

## Backend (Fastify + Prisma)

Install deps:
```bash
cd server
npm install
```

Generate Prisma client:
```bash
npm run prisma:generate
```

Run migrations:
```bash
npm run prisma:migrate
```

### Current Migration History

Five historical migration files were formatting-normalized without changing the resulting PostgreSQL schema: `20260203120000_init`, `20260321120000_add_entry_course_deleted_index`, `20260324120000_add_feedback_entry_id`, `20260429120000_add_teaching_lesson_entries`, and `20260429130000_add_capture_guidance`. Their tracked checksums therefore differ from earlier copies of the repository.

For a database that applied the earlier file contents, rebuild it and replay the complete tracked migration chain. Do not edit Prisma's `_prisma_migrations` table. Production operators must plan a controlled rebuild or replacement database before deploying this history.

Seed dev data:
```bash
npm run prisma:seed
```

Start dev server:
```bash
npm run dev
```

Build (also acts as typecheck):
```bash
npm run build
```

Start production build:
```bash
npm run start
```

## Tests

Backend tests (requires Postgres running; S3/MinIO is mocked):
```bash
cd server
npm test
```

Process-level E2E tests (requires Postgres and MinIO running):
```bash
docker compose -f infra/docker-compose.yml up -d
cd server
DATABASE_URL=postgresql://resonance:resonance@localhost:5432/resonance_test npm run prisma:migrate
DATABASE_URL=postgresql://resonance:resonance@localhost:5432/resonance_test npm run test:e2e
```

The E2E suite starts the built API on a temporary local port and covers the student submission to teacher feedback workflow over real HTTP.

iOS unit tests:

```bash
./scripts/verify-ios.sh
```

The script validates the tracked Xcode project and shared scheme, chooses an available simulator unless `IOS_DESTINATION` is set, and executes XCTest with isolated DerivedData.

## Lint/Format

Server lint:
```bash
cd server
npm run lint
```

Server format (CI enforces `format:check`):
```bash
cd server
npm run format
```

## Security (Baseline)

- Secret scan:

```bash
./scripts/secret-scan.sh
```

- Build artifact guard:

```bash
./scripts/check-no-build-artifacts.sh
```

- SCA/dependency scan (requires network access):

```bash
cd server
npm audit --audit-level=high
```

- SAST: CI runs CodeQL for `server/` (see `.github/workflows/codeql.yml`).

## Fast Loop (minimal)

```bash
docker compose -f infra/docker-compose.yml up -d
cd server
npm test
```

## Full Loop

```bash
./scripts/ci-local.sh --with-docker
```

This runs repository hygiene and security checks, backend formatting/lint/build/tests, the process-level E2E suite, and simulator XCTest.

## Graceful Shutdown

The server handles `SIGTERM` and `SIGINT` for graceful shutdown:

1. Logs the received signal.
2. Calls `app.close()`, which stops accepting new connections and drains in-flight requests.
3. Disconnects the Prisma client (`prisma.$disconnect()`).
4. Exits with code 0.

Unhandled promise rejections are logged and cause an immediate exit with code 1.

## Cleanup

Remove local build/runtime artifacts:
```bash
./scripts/clean-workspace.sh
```

## Local Pilot Demo (Mock University)

Bootstrap deterministic local demo state:
```bash
./scripts/demo/bootstrap-local-demo.sh
```

Reset demo records only:
```bash
./scripts/demo/reset-local-demo.sh
```

Screenshot instructions:

- See `docs/RELEASE_CANDIDATE_SCREENSHOTS.md`

## Production Deployment Requirements (Unvalidated)

The following is an operator checklist, not a tested deployment recipe. Choose and document infrastructure, backup, recovery, monitoring, TLS, and secret-management systems outside this repository.

### Production Prerequisites

- A reachable PostgreSQL instance
- An S3-compatible object store, e.g. MinIO in server mode
- TLS termination through an operator-managed reverse proxy or ingress
- Secrets injected via environment variables — **never hardcode in config files**

### Required Environment Variables (Production)

```bash
DATABASE_URL=postgresql://<user>:<pass>@<host>:5432/<db>

# Generate with: openssl rand -base64 48
JWT_SECRET=<strong-random-secret-at-least-32-chars>
JWT_REFRESH_SECRET=<separate-strong-random-secret>

AUTH_MODE=prod
CORS_ORIGINS=https://<your-domain>

OIDC_DISCOVERY_URL=https://<issuer>/.well-known/openid-configuration
OIDC_CLIENT_ID=<oidc-client-id>
OIDC_CLIENT_SECRET=<oidc-client-secret>
OIDC_REDIRECT_URI=https://<your-domain>/auth/oidc/callback

S3_ENDPOINT=https://minio.<your-domain>
S3_REGION=<region>
S3_BUCKET=<bucket-name>
S3_ACCESS_KEY=<s3-access-key-id>
S3_SECRET_KEY=<s3-secret-access-key>
S3_FORCE_PATH_STYLE=true  # true for MinIO path-style
```

### Reference Build and Deploy Sequence

1. **Database**: Run migrations against the production database:
   ```bash
   cd server
   DATABASE_URL=<prod-url> npx prisma migrate deploy
   ```

2. **Install, generate, and build**:
   ```bash
   cd server
   npm ci
   npm run prisma:generate
   npm run build
   ```

3. **Start**:
   ```bash
   npm run start
   ```
   The server listens on `PORT` (default 4000). Put it behind operator-managed TLS termination.

4. **Health check**: Confirm the server is up:
   ```bash
   curl -fsS https://<your-domain>/health
   ```

5. **Secrets**: Never use `CHANGE-ME` values or `minioadmin`/`resonance` credentials in production. Rotate secrets after any suspected exposure.

6. **SSO**: Set `AUTH_MODE=prod` and configure the OIDC variables above. The app opens `/auth/login`; the server redirects to `/auth/oidc/login` in production. See `docs/SECURITY.md` for the production auth contract.

### Hardening Reminders

- Set `CORS_ORIGINS` to explicit allowed origins (empty = fail-closed).
- Postgres and S3 should be encrypted at rest.
- Dev auth endpoints (`/dev/*`) are compiled in but will 404 when `AUTH_MODE` is not `dev`.
- Run `npm audit --audit-level=high` before each deployment.
- Validate this sequence in a disposable staging environment before any production use.
