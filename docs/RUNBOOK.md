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
