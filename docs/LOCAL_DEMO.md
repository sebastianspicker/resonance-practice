# Local Demo Runbook

The local demo rebuilds deterministic mock-university data for development, QA, and public screenshots. It is not production, deployment, interaction, or accessibility evidence.

## Prerequisites

- Node.js 24.x and npm 10 or later.
- Docker with Compose. No exact Docker or Compose version is pinned.
- Xcode 26 with an iOS 17-or-later Simulator runtime for app work or
  screenshots.
- A local backend environment file: `cp server/.env.example server/.env`.

Never point the demo or reset commands at a shared or production database. The safety guard requires the expected local demo database identity before destructive setup runs.

## Bootstrap the demo

From the repository root:

```bash
./scripts/demo/bootstrap-local-demo.sh
```

The script validates the fixture, starts PostgreSQL and MinIO, generates the Prisma client, applies migrations, seeds deterministic mock records, and checks service health.

To remove only records whose identifiers use the reserved `demo_` prefix:

```bash
./scripts/demo/reset-local-demo.sh
```

Then reseed with:

```bash
cd server
npm run prisma:seed:demo
```

## Use the fixture in the iOS app

1. Configure the local environment copy with `AUTH_MODE=dev`, then run `cd server && npm run dev`; keep the server loopback-only.
2. Open `ios/ResonanceApp/ResonanceApp.xcodeproj`.
3. Run the shared `ResonanceApp` scheme on an iPhone or iPad Simulator.
4. Tap sign in. The server redirects to `/dev/login`; choose `Student Persona`
   or `Teacher Persona`. The development flow uses no credentials.
5. Load mock data for the active persona.

In a Debug build, the load action is at
`Settings > Debug > Load Mock Demo Data`.

The loader derives the local course role from the active session. Load once per
student or teacher persona. `Clear Mock Demo Data` removes fixture records from
the app.

## Capture a local walkthrough

First run the full source gate from a clean commit. Then:

```bash
./scripts/demo/capture-ios-screenshots.sh
```

The capture harness creates dedicated student and teacher Simulators, builds a Debug-only screenshot configuration, captures 12 deterministic English screens, and validates PNG format, portrait dimensions, uniqueness, hashes, and clean-source metadata. Its default output is `artifacts/e2e-walkthrough/`, which is ignored and may contain local build or service logs.

Never publish the capture directory wholesale. Promote only visually reviewed PNGs and a sanitized manifest to a versioned directory under `docs/assets/screenshots/approved/`. The release process must exclude API logs, Xcode logs, derived data, local paths, tokens, and transient identifiers.

See [Screenshot Evidence](./SCREENSHOTS.md) for the promotion rules and
[Alpha Walkthrough](./ALPHA_WALKTHROUGH.md) for the exact scenarios that still
require source-freeze capture. No approved public screenshot set currently
exists.

## Acceptance checks

- [ ] The fixture validator passes.
- [ ] Seeding succeeds twice without duplicate records.
- [ ] Student data includes draft, submitted, and reviewed entries.
- [ ] Teacher data includes submitted entries awaiting review.
- [ ] The sync surface includes deterministic pending and failed examples.
- [ ] Screenshot source metadata identifies a clean commit.
- [ ] All public captures pass human visual and privacy review.
