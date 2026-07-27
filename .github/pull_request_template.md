## Summary

- What changed?
- Why is it needed?
- Which user or public release surface changes?

## Testing

- [ ] Full local CI: `./scripts/ci-local.sh --with-docker`
- [ ] If full local CI cannot run, I recorded the exact skipped gate and reason below.
- [ ] Docs and release notes are accurate for the source-only public alpha (`0.1.0-alpha.1`).
- [ ] Documentation links and commands touched by this PR were checked locally.
- [ ] API, security, support, migration, and release documentation match the implemented behavior.
- [ ] iOS screenshots, when changed, are current, reviewed, redacted, and stored only in `docs/assets/screenshots/approved/`.
- [ ] Publication-boundary guard: `./scripts/check-no-build-artifacts.sh`

## Verification Notes

- Commands run and results:
- Skipped checks and reason:

## Risk

- Runtime/API/storage/schema behavior changed?
- Migration, auth, sync, media, or data-retention impact?
- Rollback or manual verification notes?

## Release impact

- Version or changelog impact:
- Screenshot or public-doc impact:
- GitHub release, tag, or repository-metadata follow-up:

## Checklist

- [ ] No secrets/PII in logs or commits
- [ ] Docs updated (README/RUNBOOK/SECURITY as needed)
- [ ] `CHANGELOG.md` and applicable release notes are updated
- [ ] Superseded public docs are updated, removed, or intentionally retained with current context
- [ ] Local workspace notes and generated analysis files are not tracked
- [ ] No private, editor, analyzer-state, binary, or unapproved screenshot files are included
- [ ] I did not include credentials, signed URLs, environment values, private recordings, or real personal data
