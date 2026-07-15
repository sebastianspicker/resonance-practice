# Resonance

[![CI](https://github.com/sebastianspicker/resonance/actions/workflows/ci.yml/badge.svg)](https://github.com/sebastianspicker/resonance/actions/workflows/ci.yml)

Resonance is an offline-first iOS and iPadOS app for practice evidence and private teacher feedback in music education. Students can set goals, capture audio or consented teaching-lesson video, submit evidence to a course, and receive structured timestamped feedback.

`v0.1.0-alpha.1` is prepared as a source-only public alpha for developers and contributors. Until its tag and GitHub pre-release exist, the release checklist treats this branch as an unpublished candidate. It is not a signed app, a TestFlight build, a hosted service, or a production deployment.

## What the alpha includes

- SwiftUI and SwiftData client foundations for local entries, media, feedback, calendar data, and a durable sync queue.
- Student and teacher course roles, paginated hydration, local/remote reconciliation, retry and task deduplication.
- Audio and consented teaching-lesson video evidence with manual markers and private course review.
- Account-owner isolation, explicit local-profile replacement, and protected local media.
- Fastify API, Prisma/PostgreSQL schema and migrations, S3-compatible storage, loopback-only development auth, and configurable OIDC.
- Deterministic mock-university fixtures, local demo tooling, server tests, iOS XCTest, and CI-equivalent local verification.

## Known limitations

- English is the current interface language. Complete German localization and the promised English fallback remain open.
- Capture draft editing and some preview, accept, retake, reviewed-history, Calendar, Export, Settings, and Sync states need further product polish.
- The complete accessibility, assistive-technology, Dynamic Type, keyboard, device-window, and performance matrices have not been validated.
- Real OIDC, PostgreSQL, object storage, backups, retention, signing, TestFlight, and production deployment have not been validated here.
- The published screenshots are deterministic visual evidence only; they do not prove interaction, networking, authorization, persistence, or accessibility.

## Gallery

| Student evidence history | Reviewed student feedback |
|---|---|
| ![Student entry list showing draft, submitted, and reviewed practice evidence](docs/assets/screenshots/approved/v0.1.0-alpha.1/03-student-entry-list.png) | ![Reviewed student entry showing teacher comments and timestamped feedback markers](docs/assets/screenshots/approved/v0.1.0-alpha.1/12-student-reviewed-feedback.png) |

| Teacher review queue | Teacher feedback editor |
|---|---|
| ![Teacher course view showing two mock practice evidence rows](docs/assets/screenshots/approved/v0.1.0-alpha.1/08-teacher-review-queue.png) | ![Teacher feedback editor with structured comments and timestamped markers](docs/assets/screenshots/approved/v0.1.0-alpha.1/10-teacher-feedback-editor.png) |

See the [complete 12-screen alpha walkthrough](docs/ALPHA_WALKTHROUGH.md) for the student and teacher sequence, capture metadata, and evidence boundaries.

## Repository layout

- `ios/ResonanceApp/` — SwiftUI/SwiftData client and XCTest target.
- `server/` — Fastify/TypeScript API, Prisma schema, migrations, and tests.
- `infra/` — local PostgreSQL and MinIO Docker Compose services.
- `demo/` — deterministic mock-university fixture.
- `docs/` — public product, architecture, API, security, evidence, and operations docs.
- `scripts/` — local verification, cleanup, demo, and screenshot helpers.

## Local setup

Requirements: Node.js 20.x, npm, Docker Desktop, and Xcode 16 or newer with an iOS 17-or-newer runtime.

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

The copied local environment sets `AUTH_MODE=dev`. Keep `npm run dev` running in that terminal and do not expose it beyond loopback. Open `ios/ResonanceApp/ResonanceApp.xcodeproj`, select the shared `ResonanceApp` scheme, and run an iPhone or iPad Simulator. The client defaults to `http://localhost:4000`; set `RESONANCE_API_BASE` in the Xcode scheme to override it. Tap sign in, then choose **Student Persona** or **Teacher Persona** in the development login page; no credentials are used.

For deterministic mock data, run `./scripts/demo/bootstrap-local-demo.sh`; see the [local demo runbook](docs/LOCAL_DEMO.md).

## Verification

Run the complete local gate, including Docker-backed migrations, service E2E, server coverage, and iOS XCTest:

```bash
./scripts/ci-local.sh --with-docker
```

Smaller gates and database-safety requirements are documented in the [runbook](docs/RUNBOOK.md). Exact immutable verification results for this alpha belong in its [release notes](docs/release-notes/v0.1.0-alpha.1.md), not in this landing page.

## Security and privacy

- Secrets belong in environment variables and must never be committed.
- Development auth is unavailable unless explicitly enabled and is restricted to loopback clients.
- Local media uses iOS file protection; private downloads require course authorization, use short-lived URLs, and return `Cache-Control: no-store`.
- Teaching-lesson video requires explicit private-course-review consent and remains local until submission begins.

Read the [security model](docs/SECURITY.md). Report vulnerabilities through [GitHub private vulnerability reporting](https://github.com/sebastianspicker/resonance/security/advisories/new), not a public issue.

## Documentation

Start with the [documentation index](docs/INDEX.md). Product and visual contracts are in [PRODUCT.md](PRODUCT.md) and [DESIGN.md](DESIGN.md). The [alpha release checklist](docs/RELEASE_CHECKLIST.md) distinguishes completed source-release gates from open production work.

## License

MIT.
