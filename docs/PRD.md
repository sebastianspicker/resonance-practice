# PRD – Resonance: Practice & Feedback (MVP)

## Summary
Resonance is an iPad-first, offline-first practice evidence and feedback app for a German university of music. Students record short practice snippets, attach context (goal, notes, tags), submit to a course, and receive structured feedback from teachers. The MVP focuses on low-friction capture and review in environments without reliable network.

## Problem
Practice rooms often have poor connectivity. Students need an easy way to capture practice evidence and receive teacher feedback without dealing with file transfers or email. Teachers need a structured, low-noise review queue tied to course context in ILIAS.

## Goals
- Capture short audio evidence with minimal taps.
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
- Teachers: review submitted entries and provide feedback.

## Success Criteria
- Students can create and submit entries offline and see them sync when online.
- Teachers can review a queue and provide feedback that students can view.
- Minimal support burden: simple auth, clear states, and resilient sync.

## MVP Scope
- Course context via ILIAS deep link or course list.
- Practice entry creation, audio recording, local storage.
- Submit flow with pre-signed upload and server verification.
- Teacher review queue and feedback editor.
- PDF export for date range.
- Calendar view of ASIMUT iCal events.

## Risks
- SSO integration complexity; mitigated with a dev stub and documented production flow.
- Offline sync conflicts; mitigated with last-write-wins and append-only feedback.
- Media upload size and reliability; mitigated with short-form recording and resumable retries.
