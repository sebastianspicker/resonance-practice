# Resonance Specification

This document consolidates the user stories, assumptions, and data model for the Resonance MVP.

## User Stories

1. As a student, I can sign in with university SSO so that I do not need a new account.
   - Given I am on the login screen, when I tap "Sign in", then the system opens ASWebAuthenticationSession to the university SSO and returns me to the app.
2. As a student, I can open a course directly from ILIAS via a deep link so that I land in the correct context.
   - Given I open a universal link with a `courseId`, when the app starts, then it navigates to the course details.
3. As a student, I can view my course list so I can choose where to submit practice.
   - Given I am signed in, when I open Courses, then I see a list of courses I belong to.
4. As a student, I can create a practice entry with a goal and date so that I can track my work.
   - Given I am in a course, when I create a new entry with goal and date, then it is saved locally.
5. As a student, I can record audio for a practice entry so I can submit evidence.
   - Given I start a recording, when I stop, then the audio is stored locally and attached to the entry.
6. As a student, I can add tags and notes so that my teacher understands context.
   - Given I edit an entry, when I add tags and notes, then they appear in the entry detail.
7. As a student, I can submit my entry so that it appears in the teacher's queue.
   - Given I tap submit, when the network becomes available, then the entry and audio upload and the status becomes submitted.
8. As a student, I can see upload progress so I know if evidence is syncing.
   - Given an entry is syncing, when I open it, then I see the current upload state.
9. As a teacher, I can see a review queue so I can prioritize feedback.
   - Given I open the teacher queue, when there are submitted entries, then I see them ordered by date.
10. As a teacher, I can add feedback text and a status so students know what to improve.
    - Given I open a submitted entry, when I submit feedback, then it is stored and visible to the student.
11. As a teacher, I can optionally add timestamp markers so I can reference specific moments.
    - Given I am adding feedback, when I add a marker with time and note, then the marker is saved with feedback.
12. As a student, I can view feedback on my entry so I can improve.
    - Given feedback exists, when I open the entry, then I see the teacher's comments and status.
13. As a student, I can delete my entry so that I control retention.
    - Given I choose delete, when I confirm, then the entry is marked for deletion and removed from the server on sync.
14. As a student, I can export a PDF summary for a date range so I can share progress.
    - Given I select a date range, when I export, then a PDF is generated and shareable.
15. As a student, I can view my ASIMUT bookings in a calendar so I can plan practice.
    - Given I provide an iCal URL, when I open the calendar, then I see upcoming events even offline (from cache).

## Assumptions

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

## Data Model

### Server Entities

| Entity | Fields |
|--------|--------|
| User | id, displayName, globalRole |
| Course | id, title |
| Membership | userId, courseId, roleInCourse |
| PracticeEntry | id, courseId, studentId, createdAt, practiceDate, goalText, durationSeconds?, tags[], notes?, status, updatedAt, deletedAt? |
| Artifact | id, entryId, type, durationSeconds, createdAt, uploadState, storageKey?, remoteUrl? |
| Feedback | id, targetType, targetId, teacherId, createdAt, status, commentsText |
| Marker | id, feedbackId, timeSeconds, text |
| RefreshToken | id, userId, tokenHash, expiresAt, revokedAt?, createdAt |

### Relationships

- User 1..n Membership
- Course 1..n Membership
- Course 1..n PracticeEntry
- PracticeEntry 1..n Artifact
- Feedback targets PracticeEntry or Artifact
- Feedback 0..n Marker

### Sync Strategy

- Client generates UUIDs for offline creation.
- Sync queue batches create/update/delete operations.
- Upload flow: create artifact -> get pre-signed URL -> upload -> confirm.
- Conflicts: last-write-wins for entries; feedback append-only.

## Entry States

| State | Description |
|-------|-------------|
| draft | Entry is being edited, not yet submitted |
| submitted | Entry has been submitted for teacher review |
| reviewed | Teacher has provided feedback |

## User Roles

| Role | Permissions |
|------|-------------|
| student | Create/edit/delete own entries, view own feedback, export PDF |
| teacher | View course entries, provide feedback on submitted entries |

## API Error Format

API returns consistent error objects:

```json
{
  "error": {
    "code": "STRING_CODE",
    "message": "Human readable message",
    "details": { "optional": true }
  }
}
```
