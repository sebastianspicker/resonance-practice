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

## Visual review

Inspect local Simulator behavior manually when changing the app UI. Never
publish unreviewed images, logs, derived data, local paths, tokens, or transient
identifiers. The repository retains historical screenshots as product records
but does not automate UI capture.

## Acceptance checks

- [ ] The fixture validator passes.
- [ ] Seeding succeeds twice without duplicate records.
- [ ] Student data includes draft, submitted, and reviewed entries.
- [ ] Teacher data includes submitted entries awaiting review.
- [ ] The sync surface includes deterministic pending and failed examples.
- [ ] Screenshot source metadata identifies a clean commit.
- [ ] All public captures pass human visual and privacy review.
