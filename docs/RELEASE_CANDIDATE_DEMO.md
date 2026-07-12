# Local Demo Runbook

This runbook defines deterministic mock data for local QA. It is not production, deployment, or accessibility evidence.

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

1. Open `ios/ResonanceApp/ResonanceApp.xcodeproj` in Xcode.
2. Run on iPad simulator.
3. Sign in via Dev Login.
4. In a Debug build, open **Settings > Debug > Load Mock Demo Data**.
   - The loader assigns local course role from the active session (`student` or `teacher`), so load once per persona before capturing screenshots.

Use **Clear Mock Demo Data** to remove local fixture records.

## iOS Verification

The native Xcode project and shared scheme are the supported build and test path. Run `./scripts/verify-ios.sh` before capturing pilot-validation screenshots.

## Acceptance Checks

- [ ] `npm run prisma:seed:demo` succeeds twice without duplicate records.
- [ ] Teacher review queue shows multiple submitted entries.
- [ ] Student flow shows mixed statuses (`draft`, `submitted`, `reviewed`).
- [ ] Sync status shows the expected pending and failed examples.
