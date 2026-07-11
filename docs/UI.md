# UI (iPad)

## Sitemap

- Login
- Courses (list)
- Course Detail
  - Entries list
  - New Entry
  - Entry Detail
  - Submit
- Teacher Review Queue
- Feedback Editor
- Calendar (ASIMUT)
- Export
- Settings

## Key Screens

- Login: ASWebAuthenticationSession; display current environment.
- Courses: split view with course list and detail.
- New Entry: entry type selector for practice or teaching lesson; teaching lessons require private course-review consent and capture-profile selection.
- Entry Detail: audio player, teaching-lesson filming/import, notes, tags, upload state + sync phase, lesson-contour markers, feedback.
- Entry List: status badges for `draft`, `submitted`, `reviewed`.
- Recording: minimal audio controls, elapsed timer, save/cancel.
- Teaching Lesson Camera: capture-profile picker, consent/placement check, preview-only overlays for level/safe frame, teacher movement corridor, learner/instrument/group zones, no-consent zone, static contour guides, quick lesson-contour marker buttons, elapsed timer, and audio level meter. Filmed and imported lesson videos keep their capture-profile metadata.
- Teacher Queue: list of submitted entries with student, date, artifact count, and lesson marker count.
- Feedback: status picker + text + optional markers + quick snippets.
- Calendar: day/week list with cached events.
- Export: date range picker, “Generate PDF”, and local practice stats summary.
- Settings: active API host plus debug auth endpoint in dev builds.

## Edge Cases

- Offline: show sync queue and “Last synced” indicator.
- Partial upload: allow retry and keep local file.
- Deleted entries: hide from lists after sync.
- Token expiration: re-auth using refresh token.
- Entry deletion requires explicit confirmation.
