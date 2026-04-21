# Release Candidate Demo Runbook

This runbook defines the deterministic local demo flow used for release-candidate QA screenshots.

## Purpose
- Rebuild a known demo state using mock university data.
- Keep screenshots reproducible across machines.
- Avoid manual database editing.

## Preflight
1. Ensure Docker is running.
2. Ensure Node.js 20+ and npm are available.
3. Ensure Xcode is available for iPad simulator screenshots.
4. Confirm backend env exists:
   - `cp server/.env.example server/.env` (if missing)

## One-Command Demo Bootstrap
From repo root:

```bash
./scripts/demo/bootstrap-local-demo.sh
```

What it does:
- validates demo fixture integrity,
- starts Postgres + MinIO,
- runs Prisma generate + migrate,
- seeds deterministic mock demo records,
- runs health checks.

## Reset Demo Dataset
From repo root:

```bash
./scripts/demo/reset-local-demo.sh
```

This removes all DB records using `demo_` IDs. Reseed with:

```bash
cd server
npm run prisma:seed:demo
```

## iOS Demo Data Load
1. Open `ios/ResonanceApp/Package.swift` in Xcode.
2. Run on iPad simulator.
3. Sign in via Dev Login.
4. Open **Settings > Debug > Load Mock Demo Data**.
   - The loader assigns local course role from the active session (`student` or `teacher`), so load once per persona before capturing screenshots.

Use **Clear Mock Demo Data** to remove local fixture records.

## Known Build Gap
`swift test` via SwiftPM CLI currently fails due `Info.plist` resource constraints in this package setup.

For RC screenshot workflows, use Xcode scheme execution instead of `swift test`.

## Verification Checklist
- `npm run prisma:seed:demo` is idempotent (safe to run twice).
- Teacher review queue shows multiple submitted entries.
- Student flow shows mixed statuses (`draft`, `submitted`, `reviewed`).
- Queue screen shows pending/failed examples.
