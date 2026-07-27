# Contributing to Resonance

Contributions must preserve the offline workflow, private course boundary,
account isolation, consent checks, and explicit synchronization state.

## Before starting

1. Read the [project overview](README.md) and
   [documentation index](docs/INDEX.md).
2. Use Node.js 24.x and the shared `ResonanceApp` Xcode scheme.
3. Keep the change focused and preserve unrelated work.
4. Open an issue before making a substantial product, schema,
   authentication, storage, or migration change.
5. Do not use real student records or private media in development or tests.

## Development setup

Follow [Installation](README.md#installation) and
[Development and operations](docs/RUNBOOK.md). Local authentication is
unauthenticated and loopback-only.

## Implementation expectations

- Fix the shared cause of a defect instead of duplicating a workaround.
- Add tests for behavior changes, failure paths, authorization boundaries, and
  state transitions.
- Keep migrations, API contracts, Swift models, and documentation aligned.
- Preserve durable queue behavior and account ownership checks when changing
  synchronization.
- Keep private media access explicit and course-scoped.
- Avoid new production dependencies unless the change has been discussed.
- Do not include build output, local logs, private review notes, tool state, or
  unreviewed screenshots.

## Verification

Run the narrowest relevant checks while developing. Before requesting review,
run:

```bash
./scripts/ci-local.sh --with-docker
```

Useful focused checks:

```bash
cd server
npm run build
npm test
npm run lint
npm run format:check
npm run quality:dead-code
npm run quality:duplicates

cd ..
./scripts/lint-swift.sh lint
./scripts/verify-ios.sh
node scripts/validate-public-docs.mjs
node --test tests/repository/*.test.mjs
./scripts/secret-scan.sh
./scripts/check-no-build-artifacts.sh
```

SwiftLint must be version 0.63.2. CI runs iOS XCTest with the Xcode-bundled
compiler and Swift 6.3.3. If a required service or toolchain is unavailable,
list the exact skipped command and reason in the pull request.

## Pull requests

A pull request should:

- describe the user-visible or operational change;
- explain the reason for the change;
- identify schema, authentication, synchronization, storage, privacy, or
  retention effects;
- include relevant tests;
- update affected documentation;
- list commands run and their results;
- list checks that were not run and why.

Logs, screenshots, and fixtures must use synthetic data. Do not attach
credentials, tokens, signed URLs, environment files, private recordings, or
real identities.

## Screenshot changes

Keep raw captures in ignored local output. Only reviewed deterministic
screenshots and a sanitized manifest may be placed under
`docs/assets/screenshots/approved/<version>/`. Follow the
[screenshot policy](docs/SCREENSHOTS.md).

## Security reports

Do not open a public issue for a vulnerability. Follow
[SECURITY.md](SECURITY.md).
