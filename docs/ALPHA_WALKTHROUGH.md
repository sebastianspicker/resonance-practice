# Resonance v0.1.0-alpha.1 Walkthrough

This document defines the exact 12-scenario recapture required for the
source-only alpha. There is no approved public screenshot set. Historical
assets have unresolved commit provenance and visible clipping and must not be
linked or used as release evidence.

Capture all scenarios from the same clean source-freeze commit, after the
required local gates pass. Use deterministic mock-university data only. The student
scenarios use an iPhone in portrait with light appearance; the teacher scenarios
use an iPad in landscape with dark appearance so the complete review workspace is
visible. Record the simulator OS, device, orientation, appearance,
text size, filenames, dimensions, SHA-256 checksums, and source commit in the
sanitized manifest.

Screenshots are visual evidence only. They do not prove taps, networking,
authorization, persistence, accessibility, localization, signing, or
deployment. Those claims require the separate gates described in the
[release notes](./release-notes/v0.1.0-alpha.1.md).

## Student flow

### 1. Sign in

Capture the local Mock University development sign-in screen. The development
flow is loopback-only and is not a production identity-provider configuration.

### 2. Select a course

Capture the student course list with mock course content.

### 3. Review evidence status

Capture student evidence status with draft, submitted, and reviewed states
visible in words rather than color alone.

### 4. Compose a new entry

Capture a new practice-entry form with mock goal, duration, tags, and notes.

### 5. Prepare evidence for submission

Capture a student draft detail with recording controls, evidence state, and a
submission action.

### 6. Understand pending and failed work

Capture the intentional recovery-state fixture with labeled pending and failed
mock tasks and recovery actions.

## Teacher flow

### 7. Enter a teacher course

Capture the teacher course list with a selected mock course and its deliberate
pre-selection detail-pane state.

### 8. Review submitted evidence

Capture the teacher review queue with mock student practice-evidence rows.

### 9. Inspect a submission

Capture a teacher submission detail with mock practice metadata,
authorized-media state, and a feedback entry point.

### 10. Draft timestamped feedback

Capture a teacher feedback editor with a structured comment and timestamped
mock markers.

### 11. See queued feedback

Capture a teacher review queue with a clearly labeled queued-feedback state on
one mock submission.

## Student receives feedback

### 12. Read the reviewed entry

Capture a reviewed student entry with teacher comments and timestamped feedback
markers.

## Review requirements

Before publication, verify all 12 PNGs for clipping, overlap, empty frames,
incorrect role or course context, debug residue, private data, and misleading
state. Validate their count, names, PNG signatures, dimensions, uniqueness, and
manifest checksums. Do not publish capture logs, local paths, real identities,
tokens, private media, or transient Simulator identifiers. See [Screenshot
Evidence](./SCREENSHOTS.md) for the promotion policy and remaining coverage.
