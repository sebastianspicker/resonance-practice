# RUNBOOK

This runbook captures the current, reproducible commands for local development and verification.
If a command is marked "Not configured", it is a deliberate gap to be addressed in Phase 2.

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

iOS unit tests:
- Open `ios/ResonanceApp/Package.swift` in Xcode
- Run the `ResonanceAppTests` scheme

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
docker compose -f infra/docker-compose.yml up -d
cd server
npm run prisma:generate
npm run prisma:migrate
npm run prisma:seed
npm run build
npm test
```

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

## Release Candidate Demo (Mock University)
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

## Production Deployment

> ⚠️ Production SSO (Shibboleth/OIDC) is not yet implemented. The steps below apply once an SSO bridge is in place.

### Prerequisites
- A reachable PostgreSQL instance (RDS, managed DB, etc.)
- An S3-compatible object store (AWS S3 or MinIO in server mode)
- TLS termination (reverse proxy: nginx, Caddy, or a load balancer)
- Secrets injected via environment variables — **never hardcode in config files**

### Required Environment Variables (Production)

```bash
DATABASE_URL=postgresql://<user>:<pass>@<host>:5432/<db>

# Generate with: openssl rand -base64 48
JWT_SECRET=<strong-random-secret-at-least-32-chars>
JWT_REFRESH_SECRET=<separate-strong-random-secret>

AUTH_MODE=prod
APP_BASE_URL=https://<your-domain>
CORS_ORIGINS=https://<your-domain>

S3_ENDPOINT=https://s3.<region>.amazonaws.com   # or MinIO server URL
S3_REGION=<region>
S3_BUCKET=<bucket-name>
S3_ACCESS_KEY=<aws-access-key-id>
S3_SECRET_KEY=<aws-secret-access-key>
S3_FORCE_PATH_STYLE=false  # true only for MinIO path-style
```

### Deploy Steps

1. **Database**: Run migrations against the production database:
   ```bash
   cd server
   DATABASE_URL=<prod-url> npx prisma migrate deploy
   ```

2. **Build**:
   ```bash
   cd server
   npm ci --production
   npm run prisma:generate
   npm run build
   ```

3. **Start**:
   ```bash
   npm run start
   ```
   The server listens on `PORT` (default 4000). Put it behind a TLS-terminating reverse proxy.

4. **Health check**: Confirm the server is up:
   ```bash
   curl -fsS https://<your-domain>/health
   ```

5. **Secrets**: Never use `CHANGE-ME` values or `minioadmin`/`resonance` credentials in production. Rotate secrets after any suspected exposure.

6. **SSO**: Set `AUTH_MODE=prod` and wire the university Shibboleth/OIDC bridge at `/auth/session`. See `docs/SECURITY.md` for the documented production auth contract.

### Hardening Reminders
- Set `CORS_ORIGINS` to explicit allowed origins (empty = fail-closed).
- Postgres and S3 should be encrypted at rest.
- Dev auth endpoints (`/dev/*`) are compiled in but will 404 when `AUTH_MODE` is not `dev`.
- Run `npm audit --audit-level=high` before each deployment.
