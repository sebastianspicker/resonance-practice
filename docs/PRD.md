# Resonance Production-Pilot Requirements

## Product

Resonance is an offline-first native workflow for practice evidence and private teacher feedback at a university of music. Students work in practice rooms and school placements where connectivity can be unreliable; teachers commonly review on iPad with a keyboard.

## Users

- Music students recording practice evidence and reading feedback.
- Music-teacher-education students recording consented teaching lessons.
- Teachers reviewing submitted evidence and returning structured feedback.

## Production-Pilot Goals

- Preserve useful local work during poor connectivity and make sync state explicit.
- Keep account ownership, course role, consent, and media access as hard boundaries.
- Make one submission action produce one durable outcome.
- Let teachers play evidence while composing timestamped feedback.
- Support core student work on iPhone and full review work on iPad.
- Deliver German and English interfaces and Apple accessibility support.

## Current Implementation

The source tree currently includes local entry/media storage, a persistent retry queue, server-backed entry hydration, account-owner locking, course-role navigation, consent metadata, capture profiles and markers, authorized media playback, feedback queueing, PDF export, and a cached iCal calendar.

The server implements configurable OIDC and local dev auth. No live university identity provider, production storage, or production deployment is configured or proven by this repository.

## Remaining Pilot Acceptance Work

- Complete localization resources and locale-specific PDF output.
- Complete create/edit and preview/accept/retake workflows.
- Add reviewed-history and remaining secondary-screen recovery states.
- Add XCUITest accessibility audits and keyboard/role assertions.
- Run the documented device, Dynamic Type, assistive-technology, performance, and poor-network matrix.
- Validate production OIDC, PostgreSQL, object storage, TLS, backup, and retention operations.

## Non-goals

- Grades, exams, room booking, public media sharing, automated teaching analysis, face/person/pose analysis, 360/VR capture, or a public administration console.
- A full ILIAS/LTI integration. Course deep-link integration remains proposed rather than implemented.
- Automatic ASIMUT integration. The current calendar consumes a user-provided iCal URL.

## Privacy Requirements

- Teaching-lesson submission requires explicit private-course-review consent and uploaded video.
- Signed media URLs are short-lived and must not be logged.
- Different accounts cannot share local cached content.
- Sign-out discloses queued work and requires confirmation before local deletion.
- Analytics remain disabled; logs must exclude content, signed URLs, calendar URLs, names, and identifiers.
