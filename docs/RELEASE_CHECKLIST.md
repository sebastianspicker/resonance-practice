# Release Checklist

Current status: open production-pilot checklist. This repository does not yet contain real-SSO, production-storage, deployment, full localization, accessibility-matrix, or performance proof.

## Local Demo & Screenshot Gates

- [ ] Mock demo seeded (`npm run prisma:seed:demo`).
- [ ] Current reviewed screenshot set complete according to `docs/RELEASE_CANDIDATE_SCREENSHOTS.md`.

## Build/Test Gates

- [ ] Server lint/build/tests pass.
- [ ] Server runtime `/health` smoke probe passes.
- [ ] iOS simulator XCTest passes via `./scripts/verify-ios.sh`.
- [ ] Build artifact guard passes.
- [ ] Security secret scan passes.
- [ ] Shellcheck and workflow lint pass.

## Production-Pilot UI Gates

- [ ] Student and teacher course-role actions verified.
- [ ] Two-user isolation and pending-work sign-out verified.
- [ ] Fresh-install hydration, offline cache, and queued-edit merge verified.
- [ ] Owner and same-course teacher playback succeeds; unrelated access fails.
- [ ] One-tap submission waits for media and duplicate taps coalesce.
- [ ] Light/dark and German/English verified on iPhone and iPad.
- [ ] Large, AX1, AX3, AX5, Bold Text, Increase Contrast, Reduce Motion, and Reduce Transparency verified.
- [ ] VoiceOver, Voice Control, Switch Control, and keyboard traversal verified.
- [ ] Loading, empty, stale/offline, recoverable error, permission, and destructive states verified.

## Documentation Gates

- [ ] `docs/RELEASE_CANDIDATE_DEMO.md` reflects current commands.
- [ ] `docs/RELEASE_CANDIDATE_SCREENSHOTS.md` matches latest UI.
- [ ] `README.md` and `docs/RUNBOOK.md` describe the local demo without presenting it as production proof.
