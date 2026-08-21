# Releasing the Source-Only Alpha

This procedure prepares and publishes `v0.1.0-alpha.1` as a GitHub pre-release
containing source archives only. It does not cover App Store, TestFlight,
container, package-registry, or hosted-service distribution.

## Release identity

- Git tag: `v0.1.0-alpha.1`
- GitHub title: `Resonance v0.1.0-alpha.1`
- GitHub release type: pre-release
- Server package: `0.1.0-alpha.1` and `private: true`
- iOS marketing/build version: `0.1.0` (`1`)

Apple marketing versions are numeric. The Git tag and release notes carry the
pre-release suffix.

## Repository metadata

Repository description, topics, branch protection, and release settings are
GitHub-side state and must be verified separately from the source tree.
Scheduled workflows can be disabled after repository inactivity; confirm that
the Security Audit workflow is enabled and dispatch it before publication.

## 1. Freeze the candidate

1. Base the release branch on the intended `main` commit.
2. Confirm the version values above.
3. Remove local workspace state, diagnostic reports, logs, build output,
   private data, and unapproved screenshots.
4. Review `README.md`, `CHANGELOG.md`, release notes, API, security, runbook,
   support, and screenshot documentation as a fresh reader.

## 2. Verify locally

Run:

```bash
./scripts/ci-local.sh --with-docker
```

The final candidate must include a fresh disposable PostgreSQL database,
baseline migration, MinIO-backed artifact flow, strict SwiftLint, retained
server contracts, iOS XCTest, and the exact Swift toolchain. Record any blocked
command separately; a subset is not full release proof.

Also confirm:

```bash
node scripts/validate-public-docs.mjs
./scripts/secret-scan.sh
./scripts/check-no-build-artifacts.sh
git diff --check
```

## 3. Promote screenshots

1. Review any proposed product screenshots against
   [ALPHA_WALKTHROUGH.md](./ALPHA_WALKTHROUGH.md) from the exact frozen source.
2. Inspect each image for clipping, misleading state, private data, debug
   residue, and role correctness.
3. Commit only the approved PNGs, manifest, narrowly scoped screenshot
   documentation changes, and the matching versioned release note. Retain the
   earlier clean capture commit as `source.commit`, record iPhone rows as
   `iOS <version>` and iPad rows as `iPadOS <version>`, and change exactly
   `source.status` to `release-ready`,
   `verification.humanVisualInspection` to `passed`, and
   `verification.releaseReady` to `true`.
4. Rerun `node scripts/validate-public-docs.mjs --release` from that
   publication commit. It requires exactly one release-ready, human-reviewed
   manifest with exactly 12 captures.

Screenshots are visual evidence only and are not an automated test gate.

## 4. Open the release pull request

1. Review the complete patch and asset sizes.
2. Open a draft PR against `main`.
3. Require code-owner review, CI, CodeQL, dependency audit, Security Audit,
   visual QA, and fresh-reader docs review.
4. Resolve all requested changes and rerun affected gates.

Do not tag a branch-only commit. Merge first, then tag the resulting `main`
commit.

## 5. Publish

After explicit maintainer approval:

1. Create signed or annotated tag `v0.1.0-alpha.1` on the verified `main` commit.
2. Push the tag.
3. Create a GitHub pre-release using the versioned release notes.
4. Include source archives only; do not attach logs, environment files, raw
   captures, builds, private media, or diagnostic reports.
5. Verify the README, documentation links, security-reporting link, tag,
   release state, and source archives from a logged-out browser.

## 6. After publication

- Record release-specific follow-up as GitHub issues rather than ad hoc files in
  the public tree.
- Keep production deployment, signing, localization, accessibility matrices,
  and real-service validation explicitly outside the alpha claim.
- If a security problem is found, follow [SECURITY.md](../SECURITY.md) and amend
  or withdraw the pre-release as appropriate.
