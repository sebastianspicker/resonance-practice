BEGIN;

-- Hold application writes while the cross-table backfills and legacy
-- soft-delete conversion establish one atomic upgrade boundary.
ALTER TABLE "PracticeEntry" ALTER COLUMN "updatedAt" DROP DEFAULT;
LOCK TABLE "Feedback" IN SHARE ROW EXCLUSIVE MODE;

-- Backfill parent entries for feedback that pre-dates Feedback.entryId.
CREATE TYPE "AuthFlowTokenKind" AS ENUM ('oidc_state', 'prod_code');

UPDATE "Feedback" AS feedback
SET "entryId" = entry."id"
FROM "PracticeEntry" AS entry
WHERE
    feedback."entryId" IS NULL
    AND feedback."targetType" = 'entry'
    AND feedback."targetId" = entry."id";

UPDATE "Feedback" AS feedback
SET "entryId" = artifact."entryId"
FROM "Artifact" AS artifact
WHERE
    feedback."entryId" IS NULL
    AND feedback."targetType" = 'artifact'
    AND feedback."targetId" = artifact."id";

-- Preserve external storage cleanup work durably before artifact rows are removed.
CREATE TABLE "StorageDeletionJob" (
    "id" TEXT NOT NULL,
    "entryId" TEXT NOT NULL,
    "storageKey" TEXT NOT NULL,
    "attemptCount" INTEGER NOT NULL DEFAULT 0,
    "lastError" TEXT,
    "createdAt" TIMESTAMP (3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP (3) NOT NULL,
    "nextAttemptAt" TIMESTAMP (3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "StorageDeletionJob_pkey" PRIMARY KEY ("id")
);

CREATE INDEX "StorageDeletionJob_nextAttemptAt_createdAt_idx" ON "StorageDeletionJob" ("nextAttemptAt", "createdAt");
CREATE INDEX "StorageDeletionJob_entryId_idx" ON "StorageDeletionJob" ("entryId");
CREATE UNIQUE INDEX "StorageDeletionJob_storageKey_key" ON "StorageDeletionJob" ("storageKey");

-- Share production OIDC state and one-time app codes across API replicas.
CREATE TABLE "AuthFlowToken" (
    "tokenHash" TEXT NOT NULL,
    "kind" "AuthFlowTokenKind" NOT NULL,
    "userId" TEXT,
    "expiresAt" TIMESTAMP (3) NOT NULL,
    "createdAt" TIMESTAMP (3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "AuthFlowToken_pkey" PRIMARY KEY ("tokenHash")
);
CREATE INDEX "AuthFlowToken_kind_expiresAt_idx" ON "AuthFlowToken" ("kind", "expiresAt");

ALTER TABLE "Artifact"
ADD COLUMN "expectedSizeBytes" INTEGER,
ADD COLUMN "uploadExpiresAt" TIMESTAMP (3),
ADD COLUMN "confirmationToken" TEXT;

-- Track refresh-token lineages so replay containment revokes the stolen
-- rotation chain without invalidating unrelated device sessions.
ALTER TABLE "RefreshToken" ADD COLUMN "familyId" TEXT;
-- Legacy rows did not record lineage, so their predecessor/successor relation
-- cannot be reconstructed safely. Revoke them during the upgrade and require
-- reauthentication instead of leaving a stolen successor potentially active.
UPDATE "RefreshToken"
SET
    "familyId" = "id",
    "revokedAt" = COALESCE("revokedAt", CURRENT_TIMESTAMP)
WHERE "familyId" IS NULL;
ALTER TABLE "RefreshToken" ALTER COLUMN "familyId" SET NOT NULL;

-- Repair indexes that are declared in schema.prisma but were absent from the
-- original migration history. The token-hash constraint is a correctness
-- boundary; the remaining indexes support foreign-key cleanup and hot queries.
CREATE INDEX "Membership_userId_idx" ON "Membership" ("userId");
CREATE INDEX "Membership_courseId_idx" ON "Membership" ("courseId");
CREATE INDEX "PracticeEntry_status_idx" ON "PracticeEntry" ("status");
DROP INDEX IF EXISTS "Feedback_targetId_idx";
CREATE INDEX "Feedback_targetId_targetType_idx" ON "Feedback" ("targetId", "targetType");
CREATE INDEX "Feedback_teacherId_idx" ON "Feedback" ("teacherId");
CREATE INDEX "Marker_feedbackId_idx" ON "Marker" ("feedbackId");
CREATE UNIQUE INDEX "RefreshToken_tokenHash_key" ON "RefreshToken" ("tokenHash");
CREATE INDEX "RefreshToken_userId_idx" ON "RefreshToken" ("userId");
CREATE INDEX "RefreshToken_userId_familyId_idx" ON "RefreshToken" ("userId", "familyId");

-- Replace legacy full-row soft deletion with a minimal ID tombstone. Queue any
-- remaining object keys before the cascading hard delete removes artifact rows.
CREATE TABLE "DeletedEntryTombstone" (
    "id" TEXT NOT NULL,
    "deletedAt" TIMESTAMP (3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "DeletedEntryTombstone_pkey" PRIMARY KEY ("id")
);
CREATE INDEX "DeletedEntryTombstone_deletedAt_idx" ON "DeletedEntryTombstone" ("deletedAt");

INSERT INTO "DeletedEntryTombstone" ("id", "deletedAt")
SELECT "id", COALESCE("deletedAt", CURRENT_TIMESTAMP)
FROM "PracticeEntry"
WHERE "deletedAt" IS NOT NULL
ON CONFLICT ("id") DO NOTHING;

INSERT INTO "StorageDeletionJob" ("id", "entryId", "storageKey", "updatedAt")
SELECT
    'migration_' || md5(artifact."storageKey"),
    artifact."entryId",
    artifact."storageKey",
    CURRENT_TIMESTAMP
FROM "Artifact" AS artifact
JOIN "PracticeEntry" AS entry ON entry."id" = artifact."entryId"
WHERE
    entry."deletedAt" IS NOT NULL
    AND artifact."storageKey" IS NOT NULL
ON CONFLICT ("storageKey") DO NOTHING;

DELETE FROM "PracticeEntry" WHERE "deletedAt" IS NOT NULL;

COMMIT;
