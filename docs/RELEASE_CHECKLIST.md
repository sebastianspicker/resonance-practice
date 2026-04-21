# Release Checklist

## RC Demo & Screenshot Gates
- [ ] Mock demo seeded (`npm run prisma:seed:demo`).
- [ ] Screenshot set complete (all mandatory persona screens captured).
- [ ] No missing mandatory screens according to `docs/RELEASE_CANDIDATE_SCREENSHOTS.md`.

## Build/Test Gates
- [ ] Server lint/build/tests pass.
- [ ] Build artifact guard passes.
- [ ] Security secret scan passes.

## Documentation Gates
- [ ] `docs/RELEASE_CANDIDATE_DEMO.md` reflects current commands.
- [ ] `docs/RELEASE_CANDIDATE_SCREENSHOTS.md` matches latest UI.
- [ ] `README.md` and `docs/RUNBOOK.md` reference RC demo workflow.
