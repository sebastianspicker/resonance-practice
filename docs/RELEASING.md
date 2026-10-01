# Releasing

A Resonance release stays source-only unless it also ships independent
distribution and operational evidence. Never let a source release imply a hosted
service, signed application, production identity provider, or support
commitment.

Before proposing a release:

1. Confirm the public docs describe the current module and API contracts.
2. Run `./scripts/verify-repository.sh`.
3. Run `./scripts/ci-local.sh --with-docker` when its environment is available,
   following the prerequisites and database safeguards in
   [Development](./DEVELOPMENT.md), or record the exact lanes you did not run.
4. Run `node scripts/validate-public-docs.mjs` after documentation changes.
5. Review the diff for secrets, private media, generated output, and stale route
   or source-path references.
6. State separately which deployment, SSO, storage, backup, device, and
   accessibility evidence remains external.

Release notes must call out incompatible contract changes. Unversioned resource
mutations are gone by design: consumers use `POST /api/v1/sync/commands` for
resource mutations.
