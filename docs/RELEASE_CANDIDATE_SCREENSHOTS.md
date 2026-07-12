# Production-Pilot Screenshot Validation Playbook

Screenshots are supporting visual evidence, not proof of interaction, accessibility, networking, or external-service behavior. The previous `0.1.0-rc` images represented the retired glass interface and are intentionally no longer public.

## Capture Policy

- Capture from the current source after build and XCTest pass.
- Keep unreviewed output under `artifacts/screenshots/` or `docs/assets/screenshots/local/`; both are ignored.
- Publish only reviewed captures under `docs/assets/screenshots/approved/`.
- Do not restore README screenshots until they match the current interface and have been approved.
- Use mock identities and content only. Do not capture tokens, real courses, names, calendar URLs, media, or diagnostics.

## Pairwise Matrix

Cover the smallest useful pairwise set across:

- iPhone and iPad.
- Student and teacher course roles.
- Light and dark appearance.
- German and English after localization exists.
- Large, AX1, AX3, and AX5 Dynamic Type.
- Portrait, landscape, and narrow iPad window.

## Required Surfaces

- Sign-in and account-conflict protection.
- Student course, entry list, draft form, entry detail, capture review, feedback, and sync status.
- Teacher to-review queue, secure media playback, timestamped feedback, and queued-feedback outcome.
- Calendar, Export, Settings, destructive sign-out, offline, empty, permission, and recoverable-error states.

## Acceptance

- No clipped, truncated, overlapping, or hidden critical content.
- Status is understandable without color.
- No debug-only or environment information appears in release captures.
- User-generated content is deliberately long enough to exercise wrapping.
- Each capture records commit, simulator/device, OS, locale, appearance, and Dynamic Type in accompanying release notes.
