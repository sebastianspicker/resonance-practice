-- Lease queued object deletions atomically across server replicas.
ALTER TABLE "StorageDeletionJob"
  ADD COLUMN "claimToken" TEXT,
  ADD COLUMN "claimExpiresAt" TIMESTAMP(3);

CREATE INDEX "StorageDeletionJob_claimExpiresAt_idx"
  ON "StorageDeletionJob"("claimExpiresAt");

-- Support bounded maintenance scans without replacing the baseline indexes.
CREATE INDEX "Artifact_uploadState_uploadExpiresAt_idx"
  ON "Artifact"("uploadState", "uploadExpiresAt");
CREATE INDEX "ArtifactUploadSession_completedAt_idx"
  ON "ArtifactUploadSession"("completedAt");
CREATE INDEX "RefreshToken_revokedAt_idx"
  ON "RefreshToken"("revokedAt");
CREATE INDEX "Feedback_entryId_createdAt_id_idx"
  ON "Feedback"("entryId", "createdAt", "id");

-- Prisma 5 cannot declare partial indexes. These two indexes belong to the
-- active-entry cursor queries and therefore intentionally remain migration-only.
CREATE INDEX "PracticeEntry_student_cursor_active_idx"
  ON "PracticeEntry"("courseId", "studentId", "practiceDate" DESC, "createdAt" DESC, "id" DESC)
  WHERE "deletedAt" IS NULL;
CREATE INDEX "PracticeEntry_teacher_cursor_active_idx"
  ON "PracticeEntry"("courseId", "status", "practiceDate" DESC, "createdAt" DESC, "id" DESC)
  WHERE "deletedAt" IS NULL;
