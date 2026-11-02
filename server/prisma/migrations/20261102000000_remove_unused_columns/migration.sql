-- Drop never-written columns. The partial cursor indexes depend on
-- PracticeEntry.deletedAt, so they are replaced by plain indexes that Prisma can declare.
DROP INDEX IF EXISTS "PracticeEntry_student_cursor_active_idx";
DROP INDEX IF EXISTS "PracticeEntry_teacher_cursor_active_idx";
DROP INDEX IF EXISTS "PracticeEntry_courseId_deletedAt_idx";
ALTER TABLE "PracticeEntry" DROP COLUMN "deletedAt";
CREATE INDEX "PracticeEntry_student_cursor_idx"
  ON "PracticeEntry"("courseId", "studentId", "practiceDate" DESC, "createdAt" DESC, "id" DESC);
CREATE INDEX "PracticeEntry_teacher_cursor_idx"
  ON "PracticeEntry"("courseId", "status", "practiceDate" DESC, "createdAt" DESC, "id" DESC);

ALTER TABLE "Artifact" DROP COLUMN "remoteUrl", DROP COLUMN "confirmationToken";

-- Support expired-token cleanup (cleanupRevokedRefreshTokens).
CREATE INDEX "RefreshToken_expiresAt_idx" ON "RefreshToken"("expiresAt");
