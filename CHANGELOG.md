# Changelog

All notable public changes to Resonance are documented here.

## [0.1.0-alpha.1] - Unreleased

Source-only public alpha for developers and contributors. It does not include a
signed app, TestFlight build, hosted service, or production deployment. See the
[release notes](docs/release-notes/v0.1.0-alpha.1.md) for current verification,
limitations, migration expectations, and screenshots.

### Product and client

- Added offline-first SwiftUI and SwiftData foundations for entries, protected
  media, calendar data, feedback, and durable queued work.
- Added student and teacher course workflows, audio evidence, consented
  teaching-lesson video, manual markers, private review, and reviewed feedback.
- Bound local queues and cached data to the authenticated owner, with explicit
  profile replacement and fail-closed recovery for ambiguous local data.
- Adopted Swift 6 language mode, strict concurrency enforcement, structured view and
  client modules, and deterministic simulator scenarios.

### Server, sync, and storage

- Added the v1 sequential sync contract with operation receipts, optimistic
  versions, conflict results, replay authorization, and bounded admission.
- Added race-safe artifact sessions with staging-only PUT credentials,
  signer-derived expiry, leased completion claims, immutable final keys,
  conditional copy, durable deletion jobs, and bounded quotas and retention.
- Added authorized short-lived media access for owners and same-course teachers
  while denying teachers all draft entry and media reads.
- Added configurable OIDC, loopback-only development auth, refresh-token replay
  containment, explicit production listener configuration, bounded dependency
  operations, and destructive-database guards.

### Repository and quality

- Added Node.js 24, SwiftLint 0.63.2, Knip 6.27.0, jscpd 5.0.12, CodeQL,
  dependency audit, secret scanning, and public-boundary checks.
- Added a native Xcode project and shared scheme, simulator XCTest, focused
  server tests, deterministic demo fixtures, and current public documentation.
- Added concise file-purpose and contract documentation across first-party
  Swift, TypeScript, Prisma, shell tooling, configuration, and test suites.
- Added a 12-scenario student and teacher screenshot capture harness with
  explicit visual-evidence limits. The public set still requires final-commit
  recapture and review.

### Migration

- Replaced the pre-alpha migration chain with
  `20260716000000_alpha_baseline`.
- Existing alpha databases require a destructive rebuild. Back up data if
  needed and never edit Prisma's `_prisma_migrations` table manually.
