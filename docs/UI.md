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
- Entry Detail: audio player, notes, tags, upload state + sync phase, feedback.
- Entry List: status badges for `draft`, `submitted`, `reviewed`.
- Recording: minimal controls, elapsed timer, save/cancel.
- Teacher Queue: list of submitted entries with student and date.
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
