# v0.1.0-alpha.1 Release Checklist

This checklist governs the source-only public alpha. It does not authorize or claim a signed app, TestFlight build, hosted service, or production deployment.

Checked items record evidence already collected for this candidate. The release stays a pre-release until every publication gate is checked.

## Candidate and repository boundary

- [x] Candidate branch is based on the current public `main` history.
- [x] Advisory-lock database regression for the former Prisma `P2010` path passes.
- [x] Private server package version is `0.1.0-alpha.1`; iOS marketing version remains `0.1.0`, build `1`.
- [x] Root status, ledger, remediation, plan, agent-state, archive, log, cache, build, and local screenshot material is untracked and blocked from publication.
- [x] Active regression tests and the tracked Codacy analyzer pin remain present.
- [x] `git diff --check`, clean candidate status, secret scan, and publication-boundary guard pass on the final commit.

## Build and test gates

- [x] `./scripts/ci-local.sh --with-docker` passes on the final assembled candidate.
- [x] Fixture validation, migrations, readiness, process-level service E2E, and database-backed tests pass.
- [x] Server formatting, lint, TypeScript build, production dependency audit, and coverage thresholds pass.
- [x] ShellCheck, Actionlint, CodeQL configuration, and repository guards pass.
- [x] iOS generic build and simulator XCTest pass.

## Documentation and screenshots

- [x] [README](../README.md) identifies the audience, implemented scope, limitations, setup, verification, security, and source-only boundary.
- [x] [Local demo](./LOCAL_DEMO.md), [screenshot policy](./SCREENSHOTS.md), and [teaching-lesson evidence](./TEACHING_LESSON_EVIDENCE.md) reflect the current alpha.
- [x] The 12-screen [walkthrough](./ALPHA_WALKTHROUGH.md) uses descriptive alt text and deterministic mock data.
- [x] Approved screenshots come from a clean source commit and have validated hashes, dimensions, uniqueness, privacy, and human visual review.
- [x] Capture logs and local paths are absent from the public screenshot directory and manifest.
- [x] All public Markdown links and images resolve on the final commit.
- [x] A context-free reader can identify the audience, capabilities, limitations, setup, screenshot boundary, and security-reporting path.

## GitHub and publication

- [x] Bug and pull-request templates request alpha version, surface, role, device/toolchain, connectivity, redaction, full-CI, docs, and screenshot evidence.
- [x] CODEOWNERS covers release notes and approved screenshot assets.
- [x] Repository description and topics identify the iOS/iPadOS, offline-first, music-education, Fastify, Prisma, and accessibility scope.
- [x] Draft PR [`release: prepare v0.1.0-alpha.1`](https://github.com/sebastianspicker/resonance/pull/51) is opened against `main`.
- [ ] Required GitHub Actions and CodeQL checks pass on the PR.
- [ ] Visual QA and a fresh-reader documentation review pass on the PR.
- [ ] PR is merged with a merge commit; the tag is created on that merged `main` commit.
- [ ] GitHub release `Resonance v0.1.0-alpha.1` is published as a pre-release with source archives only.
- [ ] Release links and README gallery render correctly; merged and obsolete release branches are deleted.

## Open product and deployment work

These are disclosed alpha limitations, not source-publication claims:

- [ ] Complete German localization and English fallback.
- [ ] Complete capture editing, preview/accept/retake, reviewed-history, and secondary-screen recovery states.
- [ ] Run the full Dynamic Type, assistive-technology, keyboard, device-window, performance, and poor-network matrices.
- [ ] Validate real OIDC, PostgreSQL, object storage, TLS, backups, retention, monitoring, signing, TestFlight, and deployment.
