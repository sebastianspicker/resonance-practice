# Data Model

## Server Entities
- User { id, displayName, globalRole }
- Course { id, title }
- Membership { userId, courseId, roleInCourse }
- PracticeEntry { id, courseId, studentId, createdAt, practiceDate, goalText, durationSeconds?, tags[], notes?, status, updatedAt, deletedAt? } (API currently hard-deletes entries)
- Artifact { id, entryId, type, durationSeconds, createdAt, uploadState, storageKey?, remoteUrl? }
- Feedback { id, targetType, targetId, teacherId, createdAt, status, commentsText }
- Marker { id, feedbackId, timeSeconds, text }
- RefreshToken { id, userId, tokenHash, expiresAt, revokedAt?, createdAt }

## Relationships
- User 1..n Membership
- Course 1..n Membership
- Course 1..n PracticeEntry
- PracticeEntry 1..n Artifact
- Feedback targets PracticeEntry or Artifact
- Feedback 0..n Marker

## Sync Strategy
- Client generates UUIDs for offline creation.
- Sync queue batches create/update/delete operations.
- Upload flow: create artifact -> get pre-signed URL -> upload -> confirm.
- Conflicts: last-write-wins for entries; feedback append-only.
