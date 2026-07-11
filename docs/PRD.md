# PRD – Resonance: Practice & Feedback (MVP)

## Summary

Resonance is an iPad-first, offline-first practice evidence and feedback app for a German university of music. Students record short practice snippets or film/import consented teaching-lesson video, add context (goal, notes, tags), submit to a course, and receive structured feedback from teachers. The MVP focuses on low-friction capture and review in environments without reliable network.

## Problem

Practice rooms and school placement contexts often have poor connectivity. Students need an easy way to capture practice evidence or teaching-lesson evidence and receive teacher feedback without dealing with file transfers or email. Teachers need a structured, low-noise review queue tied to course context in ILIAS.

## Goals

- Capture short audio evidence with minimal taps.
- Support consented teaching-lesson video for music teacher education.
- Work offline by default; sync when network is available.
- Use university SSO (Shibboleth) with ASWebAuthenticationSession only.
- Keep data minimization and privacy-by-design as primary constraints.
- Integrate with ILIAS via deep link and show ASIMUT room bookings via iCal.

## Non-goals

- Managing official exams, grades, or committee roles.
- Booking rooms or modifying ASIMUT data.
- Full score reader/annotator.

## Users

- Students: capture practice entries and review feedback.
- Music teacher education students: submit consented teaching-lesson video for reflection-oriented review.
- Teachers: review submitted entries and provide feedback.

## Success Criteria

- Students can create and submit entries offline and see them sync when online.
- Teaching-lesson entries cannot be submitted until consent metadata is present.
- Teaching-lesson entries cannot be submitted without an uploaded lesson video artifact.
- Teachers can review a queue and provide feedback that students can view.
- Minimal support burden: simple auth, clear states, and resilient sync.

## MVP Scope

- Course context via ILIAS deep link or course list.
- Practice entry creation, audio recording, local storage.
- Teaching-lesson entry creation, consent confirmation, local video attachment, and delayed upload on submission.
- Teaching-lesson camera guidance for music teacher education: room/teacher/instrument/ensemble/group-work capture profiles, preview-only composition overlays, and manual lesson-contour markers for phases and salient pedagogical moments.
- Evidence-bounded scientific audit for teaching-lesson video; see `docs/SCIENTIFIC_AUDIT.md`.
- Submit flow with pre-signed upload and server verification.
- Teacher review queue and feedback editor.
- PDF export for date range.
- Calendar view of ASIMUT iCal events.

## Risks

- SSO integration complexity; mitigated with a dev stub and documented production flow.
- Offline sync conflicts; mitigated with last-write-wins and append-only feedback.
- Media upload size and reliability; mitigated with short-form recording, local-first storage, and resumable retries.
- Teaching-lesson privacy risk; mitigated by consent metadata, private course-review scope, preview-only manual guidance overlays, no automatic person/face/pose detection, and no public sharing workflow in the MVP.
