# v0.1.0-alpha.1 release checklist

This checklist applies to a source-only GitHub pre-release. It does not cover a
signed application, TestFlight, hosted service, or production deployment.

All verification items must be completed from the final source-freeze commit.
The working tree is not currently release evidence.

## Source and versions

- [ ] Release branch is based on the intended `main` commit.
- [ ] Worktree contains only intentional release changes.
- [ ] Server package version is `0.1.0-alpha.1`.
- [ ] iOS marketing version is `0.1.0` and build version is `1`.
- [ ] Node.js 24.x is active.
- [ ] `server/.env.example` is present, current, sanitized, and tracked.
- [ ] The only Prisma migration is
  `20260716000000_alpha_baseline`.
- [ ] A disposable database is rebuilt and migrated from the baseline without
  editing `_prisma_migrations`.

## Automated verification

- [ ] `./scripts/ci-local.sh --with-docker`
- [ ] Compact backend boundary suite passes.
- [ ] SwiftLint 0.63.2 passes.
- [ ] iOS XCTest passes with the Xcode-bundled compiler.
- [ ] iOS XCTest passes with Swift 6.3.3.
- [ ] `node scripts/validate-public-docs.mjs`
- [ ] `./scripts/secret-scan.sh`
- [ ] `./scripts/check-no-build-artifacts.sh`
- [ ] `git diff --check`

## Manual review

- [ ] Student and teacher workflows match the documented role boundaries.
- [ ] Private media and account replacement behavior are reviewed.
- [ ] README, runbook, API, architecture, security, support, and release notes
  render correctly.
- [ ] Commands, paths, environment names, links, and examples match the final
  source.
- [ ] A fresh reader can install, configure, run, test, and troubleshoot the
  repository from the documentation.
- [ ] Limitations distinguish source behavior from unvalidated external
  services and device matrices.

## Screenshots

- [ ] All 12 walkthrough scenarios are captured from the exact source-freeze
  commit.
- [ ] Every image passes clipping, role, state, privacy, and debug-content
  review.
- [ ] The sanitized manifest records the source commit, platform, device,
  dimensions, filename, and SHA-256 value.
- [ ] Reviewed PNGs and the manifest are placed under
  `docs/assets/screenshots/approved/v0.1.0-alpha.1/`.
- [ ] Every approved image has a public Markdown reference with useful alt
  text.
- [ ] `node scripts/validate-public-docs.mjs --release` passes.

## GitHub state

- [ ] Repository description and topics are current.
- [ ] Draft release pull request targets `main`.
- [ ] Required CI, CodeQL, dependency, and security checks pass.
- [ ] Code-owner and visual reviews pass.
- [ ] Pull request is merged before tagging.
- [ ] Tag `v0.1.0-alpha.1` points to the verified merged commit.
- [ ] GitHub release is marked as a pre-release and contains source archives
  only.
- [ ] README, support and security links, tag, notes, and archives are checked
  in a logged-out browser.

## Work outside this release

- German localization and complete English fallback.
- Full Dynamic Type, assistive-technology, keyboard, device-window,
  performance, and poor-network matrices.
- Live OpenID Connect, production PostgreSQL and object storage, TLS, backups,
  retention, monitoring, signing, TestFlight, and deployment validation.
