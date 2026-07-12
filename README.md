# Resonance – Practice & Feedback

[![CI](https://github.com/sebastianspicker/resonance/actions/workflows/ci.yml/badge.svg)](https://github.com/sebastianspicker/resonance/actions/workflows/ci.yml)

Resonance is an offline-first iOS and iPadOS practice-evidence and teacher-feedback application for a university of music. Students create goals, capture audio or consented teaching-lesson video, submit evidence privately to a course, and receive structured timestamped feedback.

## Current Local Status

The current checkout contains the production-pilot foundation, not a finished production release.

Implemented in source:

- SwiftData-backed local entries, media, feedback, calendar events, and sync queue.
- Course-role-aware student and teacher navigation.
- Paginated entry hydration with local/remote reconciliation.
- Deduplicated, retrying sync tasks and dependency-aware submission.
- Account-owner locking and confirmed local-data deletion on sign-out or account replacement.
- Audio and teaching-lesson video capture with consent metadata and manual markers.
- Authorized short-lived media playback for the owner or a same-course teacher.
- Native semantic light/dark UI foundations without the retired glass presentation.
- Fastify, Prisma/PostgreSQL, S3-compatible storage, dev auth, and configurable OIDC support.

Open production-pilot work:

- Complete German and English localization.
- Reusable draft editing and complete preview/accept/retake capture paths.
- Reviewed-history and remaining Calendar, Export, Settings, and Sync polish.
- A dedicated XCUITest accessibility and device-matrix target.
- Manual VoiceOver, keyboard, switch, Dynamic Type, device-window, and performance validation.
- Deployment validation with real OIDC, PostgreSQL, and object storage.

Local evidence from 2026-07-11:

- Generic iOS device build passed with Xcode 26.3.
- 125 XCTest methods passed on an iPhone 17 Pro simulator.
- Backend checks were not rerun after the latest media endpoint change because this checkout does not currently contain `server/node_modules`.

No current UI screenshots are published: the previous RC captures represented the retired interface and were removed. See the [screenshot playbook](docs/RELEASE_CANDIDATE_SCREENSHOTS.md) for future approved captures.

## Repository Layout

- `ios/ResonanceApp/` — SwiftUI/SwiftData client and XCTest target.
- `server/` — Fastify/TypeScript API, Prisma schema, and server tests.
- `infra/` — local PostgreSQL and MinIO Docker Compose services.
- `demo/` — deterministic mock-university fixture.
- `docs/` — canonical public product, architecture, API, security, and operations docs.
- `scripts/` — local verification, cleanup, and demo helpers.

## Requirements

- Node.js 20.x and npm.
- Docker Desktop for local PostgreSQL and MinIO.
- Xcode 16 or newer with an iOS 17-or-newer runtime.

## Local Development

### Backend

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

Use `AUTH_MODE=dev` only on a loopback-only local environment. The API listens on `http://localhost:4000` by default.

### iOS

Open `ios/ResonanceApp/ResonanceApp.xcodeproj`, select the shared `ResonanceApp` scheme, and run on an iPhone or iPad simulator. The client uses `http://localhost:4000` by default; set `RESONANCE_API_BASE` in the Xcode scheme to override it.

## Verification

```bash
./scripts/check-no-build-artifacts.sh
./scripts/secret-scan.sh
./scripts/verify-ios.sh
```

With Docker and server dependencies available:

```bash
./scripts/ci-local.sh --with-docker
```

Backend-only commands are documented in [the runbook](docs/RUNBOOK.md). Test database URLs must contain `test`; the test harness refuses destructive setup against other database names.

## Local Demo

`./scripts/demo/bootstrap-local-demo.sh` builds a deterministic mock-university dataset for local QA. It is not production or accessibility evidence. See [the local demo runbook](docs/RELEASE_CANDIDATE_DEMO.md).

## Security

- Dev auth is unavailable unless `AUTH_MODE=dev` and remains loopback-only.
- Secrets belong in environment variables and must not be committed.
- Local media uses iOS file protection.
- Media download URLs are authorized, short-lived, and returned with `Cache-Control: no-store`.

See [the security policy and threat model](docs/SECURITY.md). Report vulnerabilities through GitHub private vulnerability reporting, not a public issue.

## Documentation

Start at [docs/INDEX.md](docs/INDEX.md). Product direction and visual rules are defined in [PRODUCT.md](PRODUCT.md) and [DESIGN.md](DESIGN.md).

## License

MIT.
