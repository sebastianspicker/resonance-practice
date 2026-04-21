# Assumptions

- The MVP runs in a single university tenant; multi-tenant support is out of scope.
- ILIAS deep links include a `courseId` query parameter in the Universal Link (e.g., `https://resonance.example.edu/open?courseId=COURSE_123`).
- Shibboleth is exposed via an institution SSO/OIDC bridge that can issue an authorization code for a user; production wiring is documented but not implemented.
- Dev authentication uses a local HTML login page and ASWebAuthenticationSession callback to simulate SSO without embedded webviews.
- MinIO is used as S3-compatible storage in dev; production uses an institution-managed S3 or compatible object store with server-side encryption enabled.
- Media upload verification is done via `HEAD` on the object key; checksum validation is deferred.
- Audio recording is the required artifact for each PracticeEntry; video is optional and supported via file attach (recording video in-app is a stretch goal).
- Feedback is append-only on the server; teachers do not edit feedback offline.
- For conflict handling, last-write-wins is acceptable for mutable entry fields in the MVP.
- Export provides PDF summaries in-app; media ZIP is stubbed with a documented placeholder.
- iCal parsing assumes basic `VEVENT` fields (`SUMMARY`, `DTSTART`, `DTEND`, `LOCATION`) and does not implement complex timezone rules.
- UI tests are limited to a minimal smoke test only if feasible with Swift Package tooling.
