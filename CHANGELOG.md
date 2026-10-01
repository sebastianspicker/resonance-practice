# Changelog

Notable changes, grouped by area and newest first. This project follows a
lightweight version of [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Unreleased

### Fixed

- Artifact uploads now sign the `x-amz-checksum-sha256` header that clients are
  told to send. Strict S3 implementations previously rejected uploads that
  followed `requiredHeaders` (403 `SignatureDoesNotMatch`).
- Artifact completion returns exactly `artifact` and `currentVersion`; an
  internal `expired` flag no longer leaks into the response.
- Release iOS builds no longer contain the screenshot-capture path, which could
  install a fixture session and demo data when an environment variable was set.
  Debug builds define `DEBUG` again, so Settings > Debug demo-data actions work.
- CI sets `JWT_REFRESH_SECRET`, without which the server readiness probe could
  not start.

### Compatibility

- The unversioned resource routes are gone, including the reads (`GET /courses`,
  `/courses/:courseId`, `/courses/:courseId/entries`,
  `/courses/:courseId/review-queue`, `/entries/:entryId`,
  `/entries/:entryId/feedback`) as well as the mutations and legacy upload
  routes, and `GET /api/v1/me` (use `GET /auth/me`). Former retired routes now
  answer `404 NOT_FOUND` instead of `410`. The bundled iOS client uses only
  `/api/v1` and `/auth` routes.

### Architecture and tooling

- Server modules own their write rules: entry commands live in `entries`,
  feedback creation in `reviews`, media policy in `media`; `sync` is the command
  gateway. Advisory-lock namespaces live in `platform/database`. Module
  boundaries, route ownership, and the authenticated-request type are enforced
  by tests.
- iOS layers are enforced by `scripts/check-ios-layers.mjs`; the local-profile
  lifecycle moved to Core; the Xcode project uses folder-synchronized groups and
  `Package.swift` is removed.
- Local and CI S3 storage is SeaweedFS, because the pinned MinIO image can no
  longer be pulled. Existing `minio-data` Compose volumes are no longer used and
  can be removed with `docker volume rm`.
- The server type-checks tests, seeds, and benchmarks (`npm run typecheck`).
  SwiftLint analyzer rules now actually run (`./scripts/lint-swift.sh analyze`).
- Contract checks for the server run against live responses in Vitest;
  `scripts/validate-v1-contract.mjs` covers the contract document and the iOS
  projection.

### Performance and bounded work

- Paginate feedback history and load teacher review pages on demand. Review
  summaries now return marker counts, and the full marker array stays in entry
  detail. The feedback response uses the page envelope, so client and server
  must ship together.
- Bound media validation time, include streamed bodies in storage deadlines, and
  keep completion claims live for the whole storage operation.
- Move recording checksums off the main actor and bound local outbox queries and
  course reconciliation while preserving owner and retry semantics.
- Lease storage deletion jobs across workers and move revoked-token retention
  into bounded background maintenance, with supporting indexes.
- Run the two iOS compiler lanes independently and support opt-in local build
  reuse while keeping clean builds for compiler analysis.

### Architecture

- Reorganized the server as one Fastify/Prisma monolith with `app`, `platform`,
  and identity, courses, entries, media, reviews, and sync modules.
- Reorganized the SwiftUI target into `App`, `Core`, `Features`, and `SharedUI`.
- Made `POST /api/v1/sync/commands` the canonical external resource-mutation
  boundary and removed the legacy unversioned mutation routes.

### Identity

- Added issuer-scoped `ExternalIdentity` records so the same OIDC subject from
  different issuers cannot resolve to a single user.
- Extended OIDC attempts with browser-binding, nonce, and PKCE verifier hashes.
  The accompanying Prisma migration is additive.
- Bound native app PKCE to an app code challenge and exact application callback,
  separate from the browser-to-identity-provider PKCE exchange.

### Security and operations

- Require distinct, non-placeholder production JWT access and refresh signing
  secrets with at least 32 bytes of base64 or base64url key material.
- Guard the development database reset behind an exact local target,
  development mode, and explicit confirmation.
- Bind artifact uploads to content type, length, and SHA-256, then validate
  bounded ISO-BMFF M4A or MP4 container evidence before publication.

### Documentation

- Replaced obsolete flat-path and resource-route docs with the current module
  and command contracts.
- Added an app screenshot tour to the README and the static walkthrough, and
  relaxed the public-docs validator to allow tracked images with alt text.
