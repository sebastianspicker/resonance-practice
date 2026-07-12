## Summary

- What changed?
- Why is it needed?

## Testing

- [ ] Server build/typecheck: `cd server && npm run build`
- [ ] Server tests: `cd server && npm test`
- [ ] Server lint/format where relevant: `cd server && npm run lint && npm run format:check`
- [ ] iOS simulator XCTest where relevant: `./scripts/verify-ios.sh`
- [ ] Docs/GitHub-only change: no runtime verification needed

## Risk

- Runtime/API/storage/schema behavior changed?
- Migration, auth, sync, media, or data-retention impact?
- Rollback or manual verification notes?

## Checklist

- [ ] No secrets/PII in logs or commits
- [ ] Docs updated (README/RUNBOOK/SECURITY as needed)
- [ ] Superseded public docs are updated, removed, or intentionally retained with current context
- [ ] Local-only status, ledger, and generated analysis files are not tracked
- [ ] No generated, private, internal, editor, or analyzer-state files are included
