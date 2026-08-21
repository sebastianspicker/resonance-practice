# Documentation

The repository documents the current source-only alpha and a separate set of
post-alpha requirements. A requirement is not evidence that a device,
accessibility, identity, storage, signing, or deployment check has passed.

## Build, run, and operate

- [Project overview](../README.md): purpose, capabilities, limitations,
  requirements, setup, configuration, and common commands.
- [Development and operations](./RUNBOOK.md): local services, backend and iOS
  workflows, verification, probes, production application contract, and
  troubleshooting.
- [Local demo](./LOCAL_DEMO.md): deterministic fixture setup, in-app loading,
  reset behavior, and manual visual review guidance.
- [API reference](./API.md): routes, request and response contracts, limits,
  authorization, and error codes.
- [Architecture](./ARCHITECTURE.md): runtime components, data flow,
  synchronization, persistence, and test seams.

## Security and identity

- [Security policy](../SECURITY.md): supported versions and private
  vulnerability reporting.
- [Security model](./SECURITY.md): trust boundaries, implemented controls,
  privacy behavior, threats, and deployment obligations.
- [OIDC configuration](./SSO_BRIDGE.md): production authentication flow,
  required settings, role mapping, and failure cases.

## Product and interface

- [Product scope](../PRODUCT.md): users, purpose, product language, and
  accessibility targets.
- [Design system](../DESIGN.md): visual tokens, native components, layout, and
  motion.
- [Native UI behavior](./UI.md): routes, role-based actions, capture behavior,
  and validation targets.
- [Post-alpha pilot requirements](./PRD.md): remaining acceptance work and
  non-goals.
- [Teaching-lesson evidence basis](./TEACHING_LESSON_EVIDENCE.md): sources and
  product boundaries for video evidence.

## Release material

- [Release procedure](./RELEASING.md): source freeze, verification, screenshot
  review, pull request, and publication.
- [Alpha release checklist](./RELEASE_CHECKLIST.md): candidate gates and
  unresolved release work.
- [Alpha release notes](./release-notes/v0.1.0-alpha.1.md): candidate contents,
  limitations, and evidence status.
- [Screenshot policy](./SCREENSHOTS.md): capture provenance, review, promotion,
  and evidence boundaries.
- [Screenshot walkthrough](./ALPHA_WALKTHROUGH.md): the required 12-scenario
  capture set.

## Repository participation

- [Contributing](../CONTRIBUTING.md)
- [Support](../SUPPORT.md)
- [Changelog](../CHANGELOG.md)

Only current technical and product references belong in the active
documentation tree. Update the relevant document when code, configuration,
commands, data contracts, or operating requirements change.
