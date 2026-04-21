# Release Checklist

## RC Demo & Screenshot Gates
- [ ] Mock demo seeded (`npm run prisma:seed:demo`).
- [ ] Screenshot set complete (all mandatory persona screens captured).
- [ ] No missing mandatory screens according to `docs/RELEASE_CANDIDATE_SCREENSHOTS.md`.

## Build/Test Gates
- [ ] Server lint/build/tests pass.
- [ ] Server runtime `/health` smoke probe passes.
- [ ] iOS simulator build-for-testing passes.
- [ ] Build artifact guard passes.
- [ ] Security secret scan passes.
- [ ] Shellcheck and workflow lint pass.

## Documentation Gates
- [ ] `docs/RELEASE_CANDIDATE_DEMO.md` reflects current commands.
- [ ] `docs/RELEASE_CANDIDATE_SCREENSHOTS.md` matches latest UI.
- [ ] `README.md` and `docs/RUNBOOK.md` reference RC demo workflow.
