/** Release every stored object of an entry that is being deleted under its row lock. */
import type { Prisma } from '@prisma/client';
import { artifactSessionCleanupAt } from './schedule.js';

type ReleasedArtifact = {
  id: string;
  storageKey: string | null;
  uploadSessions?: ReleasedUploadSession[];
};

type ReleasedUploadSession = {
  storageKey: string;
  expiresAt: Date;
  credentialExpiresAt: Date | null;
  completionFinalKey: string | null;
  completionClaimedAt: Date | null;
  completedAt: Date | null;
};

type StorageDeletionJob = { storageKey: string; nextAttemptAt: Date };

/**
 * Queue deletion of all artifact and upload-session objects for a locked entry
 * and return its artifact IDs. Enumeration must stay inside the deleting
 * transaction; otherwise an artifact created between prefetch and delete could
 * keep feedback rows or storage keys alive after the entry is removed.
 */
export async function queueEntryMediaRelease(
  tx: Prisma.TransactionClient,
  entryId: string
): Promise<string[]> {
  const artifacts = await findEntryArtifactsForRelease(tx, entryId);
  await queueEntryStorageDeletionJobs(tx, entryId, storageDeletionJobsForArtifacts(artifacts));
  return artifacts.map((artifact) => artifact.id);
}

async function findEntryArtifactsForRelease(tx: Prisma.TransactionClient, entryId: string) {
  return tx.artifact.findMany({
    where: { entryId },
    select: {
      id: true,
      storageKey: true,
      uploadSessions: {
        select: {
          storageKey: true,
          completionFinalKey: true,
          completionClaimedAt: true,
          credentialExpiresAt: true,
          completedAt: true,
          expiresAt: true,
        },
      },
    },
  });
}

function storageDeletionJobsForArtifacts(artifacts: ReleasedArtifact[]): StorageDeletionJob[] {
  // A staging key is present both on Artifact and its upload session. Never
  // let an immediate artifact row override the session's valid-PUT grace.
  const cleanupByKey = new Map<string, Date>();
  for (const artifact of artifacts) {
    addArtifactStorageDeletionCandidates(cleanupByKey, artifact);
  }
  return [...cleanupByKey].map(([storageKey, nextAttemptAt]) => ({ storageKey, nextAttemptAt }));
}

function addArtifactStorageDeletionCandidates(
  cleanupByKey: Map<string, Date>,
  artifact: ReleasedArtifact
) {
  addStorageDeletionCandidate(cleanupByKey, artifact.storageKey, new Date());
  for (const session of artifact.uploadSessions ?? []) {
    addUploadSessionStorageDeletionCandidates(cleanupByKey, session);
  }
}

function addUploadSessionStorageDeletionCandidates(
  cleanupByKey: Map<string, Date>,
  session: ReleasedUploadSession
) {
  const cleanupAt = artifactSessionCleanupAt(session);
  addStorageDeletionCandidate(cleanupByKey, session.storageKey, cleanupAt);
  if (session.completionFinalKey) {
    addStorageDeletionCandidate(
      cleanupByKey,
      session.completionFinalKey,
      session.completedAt ? new Date() : cleanupAt
    );
  }
}

function addStorageDeletionCandidate(
  cleanupByKey: Map<string, Date>,
  storageKey: string | null,
  nextAttemptAt: Date
) {
  if (!storageKey) return;
  const previous = cleanupByKey.get(storageKey);
  if (!previous || nextAttemptAt > previous) {
    cleanupByKey.set(storageKey, nextAttemptAt);
  }
}

async function queueEntryStorageDeletionJobs(
  tx: Prisma.TransactionClient,
  entryId: string,
  storageJobs: StorageDeletionJob[]
) {
  if (storageJobs.length === 0) return;
  await tx.storageDeletionJob.createMany({
    data: storageJobs.map(({ storageKey, nextAttemptAt }) => ({
      entryId,
      storageKey,
      nextAttemptAt,
    })),
    skipDuplicates: true,
  });
}
