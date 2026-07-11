# Resonance – Practice & Feedback

[![CI](https://github.com/sebastianspicker/resonance/actions/workflows/ci.yml/badge.svg)](https://github.com/sebastianspicker/resonance/actions/workflows/ci.yml)

Offline-first, iPad-first MVP for a university of music. Students capture short audio practice evidence or consented teaching-lesson video, submit to a course, receive structured teacher feedback, and export summaries.

## Target Audience

- **Music university students** -- capture and submit practice evidence (audio recordings) with goals, notes, and tags. Track submission status and review teacher feedback with timestamped markers.
- **Music teacher education students** -- attach consented teaching-lesson videos for course review and reflect on lesson flow, modelling, participation, and next teaching steps.
- **Music teachers / professors** -- review submitted practice entries, leave structured feedback with time-aligned markers, and manage a course review queue.

## Screenshots

| Student Flow | Teacher Flow |
|---|---|
| ![Login](docs/assets/screenshots/rc/rc-0.1.0-rc-student-login-01.png) | ![Teacher Courses](docs/assets/screenshots/rc/rc-0.1.0-rc-teacher-courses-01.png) |
| ![Courses](docs/assets/screenshots/rc/rc-0.1.0-rc-student-courses-01.png) | ![Review Queue](docs/assets/screenshots/rc/rc-0.1.0-rc-teacher-teacher-review-queue-01.png) |
| ![Entry Detail](docs/assets/screenshots/rc/rc-0.1.0-rc-student-entry-detail-01.png) | ![Feedback Editor](docs/assets/screenshots/rc/rc-0.1.0-rc-teacher-feedback-editor-01.png) |
| ![Export](docs/assets/screenshots/rc/rc-0.1.0-rc-student-export-01.png) | |

> See [docs/RELEASE_CANDIDATE_SCREENSHOTS.md](docs/RELEASE_CANDIDATE_SCREENSHOTS.md) for the full screenshot matrix and capture playbook.

Production auth uses university SSO via OIDC. The app opens the server's `/auth/login` entrypoint, which routes to dev auth locally and OIDC in production.

## Features (MVP)

- Offline-first iPad app with local storage and sync queue
- Course membership and entry submission workflow
- Pre-signed audio/video uploads to S3-compatible storage (MinIO in dev)
- Teaching-lesson entries with consent metadata, capture profiles, and manual lesson-contour markers before submission
- Teacher review queue + feedback with timestamped markers
- Token-based auth with refresh rotation; local dev auth and production OIDC entrypoints

## Monorepo Layout

- `ios/ResonanceApp/` — SwiftUI iPad app with a native Xcode project and shared scheme
- `server/` — Node.js TypeScript backend (Fastify + Prisma)
- `infra/` — Docker Compose for Postgres + MinIO
- `docs/` — Current product, architecture, security, release, and operations docs
- `scripts/` — Helper scripts

## Main Workflows for Maintainers

- **Login/session:** iOS opens `GET /auth/login`. The server chooses the concrete flow: localhost dev auth in `AUTH_MODE=dev`, university OIDC in `AUTH_MODE=prod`, then `POST /auth/session` exchanges the internal code for app tokens.
- **Student capture and sync:** entries and media artifacts are created locally first. Practice audio uploads through the normal sync queue; teaching-lesson video stays local until consent is confirmed and the student starts submission. `SyncManager` coordinates auth/network/retry, `QueueStore` owns SwiftData queue state, and `TaskExecutor` performs API calls plus S3-compatible uploads.
- **Teacher review:** teachers read submitted entries through cursor-paginated course endpoints and create feedback. Any entry-level or artifact-level feedback marks the parent entry as reviewed.
- **Deletion:** iOS removes local entries and queued child work first. The backend then performs database cascade cleanup in one transaction and deletes object-storage files after the transaction returns their storage keys.

## Requirements

- Node.js 20.x + npm
- Docker Desktop (Postgres + MinIO)
- Xcode 16+ with an iOS 17 simulator runtime (the app is designed for iPad)

## Quick Start (Local Dev)

### 1) Backend

#### Step 1: Copy the environment file and set dev auth

```bash
cp server/.env.example server/.env
```

Make sure `AUTH_MODE=dev` is set in `server/.env` for local development.

#### Step 2: Start Postgres and MinIO

```bash
docker compose -f infra/docker-compose.yml up -d
```

#### Step 3: Install dependencies, generate Prisma, migrate, and seed

```bash
cd server
npm install
npm run prisma:generate
npm run prisma:migrate
npm run prisma:seed
```

#### Step 4: Start the API

```bash
npm run dev
```

API runs on `http://localhost:4000`.

### 2) iOS (iPad) app

Open the tracked Xcode project:

```bash
open ios/ResonanceApp/ResonanceApp.xcodeproj
```

1. Select the **ResonanceApp** scheme and an **iPad simulator** as the run destination.
2. Run the app. It opens a login screen; tap "Sign In" to authenticate via the local dev server.
3. Choose a student or teacher persona. The dev server seeds a sample course ("Piano Technique 101") with a submitted entry ready for review.

The app connects to `http://localhost:4000` by default. Override with the `RESONANCE_API_BASE` environment variable in the Xcode scheme if needed.

## Configuration

Backend environment variables (see `server/.env.example`):

- `DATABASE_URL` — Postgres connection string
- `JWT_SECRET` — signing key for access tokens (required, >= 32 chars)
- `JWT_REFRESH_SECRET` — signing key for refresh tokens (optional; defaults to `JWT_SECRET + '-refresh'`)
- `AUTH_MODE` — `dev` or `prod` (defaults to `prod`)
- `CORS_ORIGINS` — comma-separated allowlist (empty = fail-closed, no cross-origin access)
- `S3_*` — MinIO/S3 endpoint + credentials

## Development Scripts (Server)

```bash
cd server
npm run dev          # start dev server
npm run build        # TypeScript build
npm run start        # run compiled server
npm run clean        # remove local build/test artifacts in server/
npm test             # run tests (requires Postgres)
npm run test:e2e     # run process-level HTTP E2E tests (requires Postgres + MinIO)
npm run lint         # ESLint
npm run format       # Prettier (write)
npm run format:check # Prettier (check)
```

Workspace cleanup (repo root):
```bash
./scripts/clean-workspace.sh
```

## Tests

Backend tests require Postgres running and `DATABASE_URL` pointing to a test database (must include `test`, e.g. `resonance_test`):

```bash
docker compose -f infra/docker-compose.yml up -d
cd server
npm test
```

iOS tests run through the tracked `ResonanceApp.xcodeproj` and shared `ResonanceApp` scheme. The verification script selects an available iPhone simulator deterministically, uses isolated DerivedData, and executes XCTest:

```bash
./scripts/verify-ios.sh
```

Set `IOS_DESTINATION` to override the selected simulator when needed.

Process-level E2E tests run the built server on a temporary local port and drive real HTTP requests against local Postgres and MinIO:

```bash
docker compose -f infra/docker-compose.yml up -d
cd server
DATABASE_URL=postgresql://resonance:resonance@localhost:5432/resonance_test npm run prisma:migrate
DATABASE_URL=postgresql://resonance:resonance@localhost:5432/resonance_test npm run test:e2e
```

`./scripts/ci-local.sh --with-docker` runs this E2E suite as part of the full local verification path.

## Validation (build / run / test)

To verify the repo end-to-end:

```bash
# Infra + backend: build and test
docker compose -f infra/docker-compose.yml up -d
cd server && npm install && npm run prisma:generate && npm run prisma:migrate && npm run prisma:seed
npm run build && npm run start &
curl -fsS http://127.0.0.1:4000/health
npm test
npm run test:e2e

# Full CI-style check from repo root (starts Postgres and MinIO if needed)
./scripts/ci-local.sh --with-docker

# Secret scan (from repo root)
./scripts/secret-scan.sh
```

`./scripts/ci-local.sh` defaults `DATABASE_URL` to `resonance_test` to match CI and the Vitest safety guard.

## RC Demo Bootstrap (Mock University)

For deterministic local release-candidate screenshots:

```bash
./scripts/demo/bootstrap-local-demo.sh
```

This seeds canonical mock data from `demo/fixtures/mock-university.json`.

To reset demo records only:

```bash
./scripts/demo/reset-local-demo.sh
```

## RC Demo Screenshots

Stored in `docs/assets/screenshots/rc/`. See [docs/RELEASE_CANDIDATE_SCREENSHOTS.md](docs/RELEASE_CANDIDATE_SCREENSHOTS.md) for the full matrix and capture workflow.

## Security

- Dev auth endpoints (`/dev/*`) are disabled unless `AUTH_MODE=dev` and are restricted to localhost requests.
- Local docker-compose ports are bound to `127.0.0.1`, and the bundled Postgres/MinIO credentials are for local development only.
- Secret scanning: `./scripts/secret-scan.sh`
- Dependency audit: `npm audit --audit-level=high` (in `server/`)
- SAST: CodeQL runs in GitHub Actions (`.github/workflows/codeql.yml`)

## API Notes

- `DELETE /entries/:entryId` hard-deletes entries and associated artifacts/feedback, and deletes storage objects.
- `GET /auth/login` is the app-facing login entrypoint. In local dev it redirects to `/dev/login`; in production it redirects to the configured OIDC flow.

## Troubleshooting

- **`docker compose` not found**: Ensure Docker Desktop is installed and running.
- **Prisma cannot reach DB**: Confirm Postgres is running and `DATABASE_URL` is set.
- **Dev auth endpoints 404**: Set `AUTH_MODE=dev` in `server/.env`.
- **CORS issues in prod**: Set `CORS_ORIGINS` to explicit allowed origins.

## Docs

- `docs/INDEX.md` — Canonical documentation entry point
- `docs/PRD.md` — Product requirements
- `docs/ARCHITECTURE.md` — Architecture
- `docs/API.md` — API reference
- `docs/UI.md` — UI spec
- `docs/SECURITY.md` — Security documentation
- `docs/SCIENTIFIC_AUDIT.md` — evidence matrix for teaching-lesson video and music teacher education
- `docs/RUNBOOK.md` — Ops runbook
- `docs/RELEASE_CANDIDATE_DEMO.md` — RC demo bootstrap and preflight
- `docs/RELEASE_CANDIDATE_SCREENSHOTS.md` — screenshot matrix and capture playbook
- `docs/RELEASE_CHECKLIST.md` — release gates checklist

## License

MIT.
