-- Resonance alpha baseline.
--
-- The pre-release migration chain was intentionally squashed. Existing alpha
-- databases and local development volumes must be discarded and rebuilt from
-- this baseline; this migration is not an in-place production upgrade.

CREATE TYPE "GlobalRole" AS ENUM ('student', 'teacher');
CREATE TYPE "CourseRole" AS ENUM ('student', 'teacher');
CREATE TYPE "EntryStatus" AS ENUM ('draft', 'submitted', 'reviewed');
CREATE TYPE "EntryKind" AS ENUM ('practice', 'teaching_lesson');
CREATE TYPE "ConsentScope" AS ENUM ('private_course_review');
CREATE TYPE "CaptureProfile" AS ENUM (
    'room_overview',
    'teacher_learner',
    'instrument_closeup',
    'ensemble_group',
    'group_work'
);
CREATE TYPE "CaptureMarkerKind" AS ENUM (
    'phase_setup',
    'phase_modeling',
    'phase_guided_practice',
    'phase_student_work',
    'phase_feedback',
    'phase_reflection',
    'moment_question',
    'moment_musical_model',
    'moment_student_response',
    'moment_transition',
    'privacy_note'
);
CREATE TYPE "ArtifactType" AS ENUM ('audio', 'video');
CREATE TYPE "UploadState" AS ENUM ('pending', 'uploading', 'uploaded', 'failed');
CREATE TYPE "FeedbackStatus" AS ENUM ('ok', 'needs_revision', 'next_goal');
CREATE TYPE "FeedbackTargetType" AS ENUM ('entry', 'artifact');
CREATE TYPE "AuthFlowTokenKind" AS ENUM ('oidc_state', 'prod_code');

CREATE TABLE "User" (
    "id" TEXT NOT NULL,
    "displayName" TEXT NOT NULL,
    "globalRole" "GlobalRole" NOT NULL,
    CONSTRAINT "User_pkey" PRIMARY KEY ("id")
);

CREATE TABLE "Course" (
    "id" TEXT NOT NULL,
    "title" TEXT NOT NULL,
    CONSTRAINT "Course_pkey" PRIMARY KEY ("id")
);

CREATE TABLE "Membership" (
    "userId" TEXT NOT NULL,
    "courseId" TEXT NOT NULL,
    "roleInCourse" "CourseRole" NOT NULL,
    CONSTRAINT "Membership_pkey" PRIMARY KEY ("userId", "courseId")
);

CREATE TABLE "PracticeEntry" (
    "id" TEXT NOT NULL,
    "courseId" TEXT NOT NULL,
    "studentId" TEXT NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "kind" "EntryKind" NOT NULL DEFAULT 'practice',
    "practiceDate" TIMESTAMP(3) NOT NULL,
    "goalText" TEXT NOT NULL,
    "durationSeconds" INTEGER,
    "tags" TEXT [] NOT NULL,
    "notes" TEXT,
    "status" "EntryStatus" NOT NULL DEFAULT 'draft',
    "consentConfirmedAt" TIMESTAMP(3),
    "consentScope" "ConsentScope",
    "captureProfile" "CaptureProfile",
    "updatedAt" TIMESTAMP(3) NOT NULL,
    "deletedAt" TIMESTAMP(3),
    "version" INTEGER NOT NULL DEFAULT 1,
    CONSTRAINT "PracticeEntry_pkey" PRIMARY KEY ("id")
);

CREATE TABLE "DeletedEntryTombstone" (
    "id" TEXT NOT NULL,
    "deletedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "DeletedEntryTombstone_pkey" PRIMARY KEY ("id")
);

CREATE TABLE "Artifact" (
    "id" TEXT NOT NULL,
    "entryId" TEXT NOT NULL,
    "type" "ArtifactType" NOT NULL,
    "durationSeconds" INTEGER NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "uploadState" "UploadState" NOT NULL DEFAULT 'pending',
    "storageKey" TEXT,
    "remoteUrl" TEXT,
    "expectedSizeBytes" INTEGER,
    "uploadExpiresAt" TIMESTAMP(3),
    "confirmationToken" TEXT,
    "failedAt" TIMESTAMP(3),
    CONSTRAINT "Artifact_pkey" PRIMARY KEY ("id")
);

CREATE TABLE "StorageDeletionJob" (
    "id" TEXT NOT NULL,
    "entryId" TEXT NOT NULL,
    "storageKey" TEXT NOT NULL,
    "attemptCount" INTEGER NOT NULL DEFAULT 0,
    "lastError" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,
    "nextAttemptAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "StorageDeletionJob_pkey" PRIMARY KEY ("id")
);

CREATE TABLE "AuthFlowToken" (
    "tokenHash" TEXT NOT NULL,
    "kind" "AuthFlowTokenKind" NOT NULL,
    "userId" TEXT,
    "expiresAt" TIMESTAMP(3) NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "AuthFlowToken_pkey" PRIMARY KEY ("tokenHash")
);

CREATE TABLE "CaptureMarker" (
    "id" TEXT NOT NULL,
    "entryId" TEXT NOT NULL,
    "artifactId" TEXT NOT NULL,
    "studentId" TEXT NOT NULL,
    "timeSeconds" INTEGER NOT NULL,
    "kind" "CaptureMarkerKind" NOT NULL,
    "note" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "CaptureMarker_pkey" PRIMARY KEY ("id")
);

CREATE TABLE "Feedback" (
    "id" TEXT NOT NULL,
    "targetType" "FeedbackTargetType" NOT NULL,
    "targetId" TEXT NOT NULL,
    "teacherId" TEXT NOT NULL,
    "entryId" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "status" "FeedbackStatus" NOT NULL,
    "commentsText" TEXT NOT NULL,
    CONSTRAINT "Feedback_pkey" PRIMARY KEY ("id")
);

CREATE TABLE "Marker" (
    "id" TEXT NOT NULL,
    "feedbackId" TEXT NOT NULL,
    "timeSeconds" INTEGER NOT NULL,
    "text" TEXT NOT NULL,
    CONSTRAINT "Marker_pkey" PRIMARY KEY ("id")
);

CREATE TABLE "RefreshToken" (
    "id" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "familyId" TEXT NOT NULL,
    "tokenHash" TEXT NOT NULL,
    "expiresAt" TIMESTAMP(3) NOT NULL,
    "revokedAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "RefreshToken_pkey" PRIMARY KEY ("id")
);

CREATE TABLE "SyncReceipt" (
    "id" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "operationId" TEXT NOT NULL,
    "kind" TEXT NOT NULL,
    "payloadHash" TEXT NOT NULL,
    "resultJson" JSONB NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "SyncReceipt_pkey" PRIMARY KEY ("id")
);

CREATE TABLE "ArtifactUploadSession" (
    "id" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "operationId" TEXT NOT NULL,
    "payloadHash" TEXT NOT NULL,
    "artifactId" TEXT NOT NULL,
    "storageKey" TEXT NOT NULL,
    "expiresAt" TIMESTAMP(3) NOT NULL,
    "credentialExpiresAt" TIMESTAMP(3),
    "completedAt" TIMESTAMP(3),
    "completionClaimToken" TEXT,
    "completionFinalKey" TEXT,
    "completionClaimedAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "ArtifactUploadSession_pkey" PRIMARY KEY ("id")
);

CREATE INDEX "Membership_userId_idx" ON "Membership" ("userId");
CREATE INDEX "Membership_courseId_idx" ON "Membership" ("courseId");
CREATE INDEX "PracticeEntry_courseId_idx" ON "PracticeEntry" ("courseId");
CREATE INDEX "PracticeEntry_studentId_idx" ON "PracticeEntry" ("studentId");
CREATE INDEX "PracticeEntry_status_idx" ON "PracticeEntry" ("status");
CREATE INDEX "PracticeEntry_courseId_deletedAt_idx" ON "PracticeEntry" ("courseId", "deletedAt");
CREATE INDEX "DeletedEntryTombstone_deletedAt_idx" ON "DeletedEntryTombstone" ("deletedAt");
CREATE INDEX "Artifact_entryId_idx" ON "Artifact" ("entryId");
CREATE INDEX "Artifact_uploadState_failedAt_idx" ON "Artifact" ("uploadState", "failedAt");
CREATE UNIQUE INDEX "StorageDeletionJob_storageKey_key" ON "StorageDeletionJob" ("storageKey");
CREATE INDEX "StorageDeletionJob_nextAttemptAt_createdAt_idx" ON "StorageDeletionJob" ("nextAttemptAt", "createdAt");
CREATE INDEX "StorageDeletionJob_entryId_idx" ON "StorageDeletionJob" ("entryId");
CREATE INDEX "AuthFlowToken_kind_expiresAt_idx" ON "AuthFlowToken" ("kind", "expiresAt");
CREATE INDEX "CaptureMarker_entryId_idx" ON "CaptureMarker" ("entryId");
CREATE INDEX "CaptureMarker_artifactId_idx" ON "CaptureMarker" ("artifactId");
CREATE INDEX "CaptureMarker_studentId_idx" ON "CaptureMarker" ("studentId");
CREATE INDEX "Feedback_targetId_targetType_idx" ON "Feedback" ("targetId", "targetType");
CREATE INDEX "Feedback_teacherId_idx" ON "Feedback" ("teacherId");
CREATE INDEX "Feedback_entryId_idx" ON "Feedback" ("entryId");
CREATE INDEX "Marker_feedbackId_idx" ON "Marker" ("feedbackId");
CREATE UNIQUE INDEX "RefreshToken_tokenHash_key" ON "RefreshToken" ("tokenHash");
CREATE INDEX "RefreshToken_userId_idx" ON "RefreshToken" ("userId");
CREATE INDEX "RefreshToken_userId_familyId_idx" ON "RefreshToken" ("userId", "familyId");
CREATE UNIQUE INDEX "SyncReceipt_userId_operationId_key" ON "SyncReceipt" ("userId", "operationId");
CREATE INDEX "SyncReceipt_createdAt_idx" ON "SyncReceipt" ("createdAt");
CREATE UNIQUE INDEX "ArtifactUploadSession_userId_operationId_key" ON "ArtifactUploadSession" ("userId", "operationId");
CREATE UNIQUE INDEX "ArtifactUploadSession_userId_artifactId_key" ON "ArtifactUploadSession" ("userId", "artifactId");
CREATE INDEX "ArtifactUploadSession_artifactId_idx" ON "ArtifactUploadSession" ("artifactId");
CREATE INDEX "ArtifactUploadSession_expiresAt_idx" ON "ArtifactUploadSession" ("expiresAt");
CREATE INDEX "ArtifactUploadSession_completionClaimedAt_idx" ON "ArtifactUploadSession" ("completionClaimedAt");

ALTER TABLE "Membership"
ADD CONSTRAINT "Membership_userId_fkey"
FOREIGN KEY ("userId") REFERENCES "User" ("id")
ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "Membership"
ADD CONSTRAINT "Membership_courseId_fkey"
FOREIGN KEY ("courseId") REFERENCES "Course" ("id")
ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "PracticeEntry"
ADD CONSTRAINT "PracticeEntry_courseId_fkey"
FOREIGN KEY ("courseId") REFERENCES "Course" ("id")
ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "PracticeEntry"
ADD CONSTRAINT "PracticeEntry_studentId_fkey"
FOREIGN KEY ("studentId") REFERENCES "User" ("id")
ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "Artifact"
ADD CONSTRAINT "Artifact_entryId_fkey"
FOREIGN KEY ("entryId") REFERENCES "PracticeEntry" ("id")
ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "CaptureMarker"
ADD CONSTRAINT "CaptureMarker_entryId_fkey"
FOREIGN KEY ("entryId") REFERENCES "PracticeEntry" ("id")
ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "CaptureMarker"
ADD CONSTRAINT "CaptureMarker_artifactId_fkey"
FOREIGN KEY ("artifactId") REFERENCES "Artifact" ("id")
ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "CaptureMarker"
ADD CONSTRAINT "CaptureMarker_studentId_fkey"
FOREIGN KEY ("studentId") REFERENCES "User" ("id")
ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "Feedback"
ADD CONSTRAINT "Feedback_teacherId_fkey"
FOREIGN KEY ("teacherId") REFERENCES "User" ("id")
ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "Feedback"
ADD CONSTRAINT "Feedback_entryId_fkey"
FOREIGN KEY ("entryId") REFERENCES "PracticeEntry" ("id")
ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "Marker"
ADD CONSTRAINT "Marker_feedbackId_fkey"
FOREIGN KEY ("feedbackId") REFERENCES "Feedback" ("id")
ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "RefreshToken"
ADD CONSTRAINT "RefreshToken_userId_fkey"
FOREIGN KEY ("userId") REFERENCES "User" ("id")
ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "SyncReceipt"
ADD CONSTRAINT "SyncReceipt_userId_fkey"
FOREIGN KEY ("userId") REFERENCES "User" ("id")
ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "ArtifactUploadSession"
ADD CONSTRAINT "ArtifactUploadSession_userId_fkey"
FOREIGN KEY ("userId") REFERENCES "User" ("id")
ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "ArtifactUploadSession"
ADD CONSTRAINT "ArtifactUploadSession_artifactId_fkey"
FOREIGN KEY ("artifactId") REFERENCES "Artifact" ("id")
ON DELETE CASCADE ON UPDATE CASCADE;
