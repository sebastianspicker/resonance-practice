## Summary

- What changed?
- Why is it needed?

## Testing

- [ ] Full local CI: `./scripts/ci-local.sh --with-docker`
- [ ] If full local CI cannot run, I recorded the exact skipped gate and reason below.
- [ ] Docs and release notes are accurate for the source-only public alpha (`0.1.0-alpha.1`).
- [ ] Documentation links and commands touched by this PR were checked locally.
- [ ] iOS screenshots, when changed, are current, reviewed, redacted, and stored only in `docs/assets/screenshots/approved/`.
- [ ] Publication-boundary guard: `./scripts/check-no-build-artifacts.sh`

## Verification Notes

- Commands run and results:
- Skipped checks and reason:

## Risk

- Runtime/API/storage/schema behavior changed?
- Migration, auth, sync, media, or data-retention impact?
- Rollback or manual verification notes?

## Checklist

- [ ] No secrets/PII in logs or commits
- [ ] Docs updated (README/RUNBOOK/SECURITY as needed)
- [ ] `CHANGELOG.md` and applicable release notes are updated
- [ ] Superseded public docs are updated, removed, or intentionally retained with current context
- [ ] Local-only status, ledger, and generated analysis files are not tracked
- [ ] No generated, private, internal, editor, analyzer-state, binary, or unapproved screenshot files are included
