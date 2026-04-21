-- Create enums
CREATE TYPE "GlobalRole" AS ENUM ('student', 'teacher');
CREATE TYPE "CourseRole" AS ENUM ('student', 'teacher');
CREATE TYPE "EntryStatus" AS ENUM ('draft', 'submitted');
CREATE TYPE "ArtifactType" AS ENUM ('audio', 'video');
CREATE TYPE "UploadState" AS ENUM ('pending', 'uploading', 'uploaded', 'failed');
CREATE TYPE "FeedbackStatus" AS ENUM ('ok', 'needs_revision', 'next_goal');
CREATE TYPE "FeedbackTargetType" AS ENUM ('entry', 'artifact');

-- Create tables
CREATE TABLE "User" (
  "id" TEXT PRIMARY KEY,
  "displayName" TEXT NOT NULL,
  "globalRole" "GlobalRole" NOT NULL
);

CREATE TABLE "Course" (
  "id" TEXT PRIMARY KEY,
  "title" TEXT NOT NULL
);

CREATE TABLE "Membership" (
  "userId" TEXT NOT NULL,
  "courseId" TEXT NOT NULL,
  "roleInCourse" "CourseRole" NOT NULL,
  PRIMARY KEY ("userId", "courseId")
);

CREATE TABLE "PracticeEntry" (
  "id" TEXT PRIMARY KEY,
  "courseId" TEXT NOT NULL,
  "studentId" TEXT NOT NULL,
  "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "practiceDate" TIMESTAMP(3) NOT NULL,
  "goalText" TEXT NOT NULL,
  "durationSeconds" INTEGER,
  "tags" TEXT[] NOT NULL,
  "notes" TEXT,
  "status" "EntryStatus" NOT NULL DEFAULT 'draft',
  "updatedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "deletedAt" TIMESTAMP(3)
);

CREATE TABLE "Artifact" (
  "id" TEXT PRIMARY KEY,
  "entryId" TEXT NOT NULL,
  "type" "ArtifactType" NOT NULL,
  "durationSeconds" INTEGER NOT NULL,
  "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "uploadState" "UploadState" NOT NULL DEFAULT 'pending',
  "storageKey" TEXT,
  "remoteUrl" TEXT
);

CREATE TABLE "Feedback" (
  "id" TEXT PRIMARY KEY,
  "targetType" "FeedbackTargetType" NOT NULL,
  "targetId" TEXT NOT NULL,
  "teacherId" TEXT NOT NULL,
  "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "status" "FeedbackStatus" NOT NULL,
  "commentsText" TEXT NOT NULL
);

CREATE TABLE "Marker" (
  "id" TEXT PRIMARY KEY,
  "feedbackId" TEXT NOT NULL,
  "timeSeconds" INTEGER NOT NULL,
  "text" TEXT NOT NULL
);

CREATE TABLE "RefreshToken" (
  "id" TEXT PRIMARY KEY,
  "userId" TEXT NOT NULL,
  "tokenHash" TEXT NOT NULL,
  "expiresAt" TIMESTAMP(3) NOT NULL,
  "revokedAt" TIMESTAMP(3),
  "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Foreign keys
ALTER TABLE "Membership" ADD CONSTRAINT "Membership_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "Membership" ADD CONSTRAINT "Membership_courseId_fkey" FOREIGN KEY ("courseId") REFERENCES "Course"("id") ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE "PracticeEntry" ADD CONSTRAINT "PracticeEntry_courseId_fkey" FOREIGN KEY ("courseId") REFERENCES "Course"("id") ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "PracticeEntry" ADD CONSTRAINT "PracticeEntry_studentId_fkey" FOREIGN KEY ("studentId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE "Artifact" ADD CONSTRAINT "Artifact_entryId_fkey" FOREIGN KEY ("entryId") REFERENCES "PracticeEntry"("id") ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE "Feedback" ADD CONSTRAINT "Feedback_teacherId_fkey" FOREIGN KEY ("teacherId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "Marker" ADD CONSTRAINT "Marker_feedbackId_fkey" FOREIGN KEY ("feedbackId") REFERENCES "Feedback"("id") ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE "RefreshToken" ADD CONSTRAINT "RefreshToken_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- Indexes
CREATE INDEX "PracticeEntry_courseId_idx" ON "PracticeEntry"("courseId");
CREATE INDEX "PracticeEntry_studentId_idx" ON "PracticeEntry"("studentId");
CREATE INDEX "Artifact_entryId_idx" ON "Artifact"("entryId");
CREATE INDEX "Feedback_targetId_idx" ON "Feedback"("targetId");
