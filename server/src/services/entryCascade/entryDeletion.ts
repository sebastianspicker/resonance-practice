import type { FeedbackTargetType, PrismaClient } from '@prisma/client';
import { ErrorCodes } from '../../errorCodes.js';
import { ApiError, isPrismaError } from '../../errors.js';
import {
  artifactSessionCleanupAt,
  type EntryTransaction,
  lockEntry,
  lockEntryIdentity,
} from '../entryTransaction.js';

/**
 * Hard-delete an entry and its associated data in one transaction, retaining
 * only a minimal ID tombstone to prevent stale offline work from reusing the
 * identifier. Storage keys are durably queued before artifact rows disappear.
 */
export async function cascadeDeleteEntry(prisma: PrismaClient, entryId: string): Promise<string[]> {
  try {
    return await prisma.$transaction((tx) => cascadeDeleteEntryInTransaction(tx, entryId));
  } catch (err: unknown) {
    if (isPrismaError(err, 'P2025')) {
      throw new ApiError(404, ErrorCodes.ENTRY_NOT_FOUND, 'Entry not found');
    }
    throw err;
  }
}

/**
 * Transaction-aware entry deletion for callers that must commit additional
 * state, such as a sync receipt, in the same atomic boundary.
 */
export async function cascadeDeleteEntryInTransaction(
  tx: EntryTransaction,
  entryId: string
): Promise<string[]> {
  // The advisory ID lock prevents a concurrent create from reusing this ID
  // after the row is deleted but before its tombstone is committed.
  await lockEntryIdentity(tx, entryId);
  const entry = await lockEntry(tx, entryId);
  if (entry.deletedAt) {
    throw new ApiError(410, ErrorCodes.ENTRY_DELETED, 'Entry has been deleted');
  }

  // Keep artifact enumeration inside the same transaction as the cascade.
  // Otherwise an artifact created between prefetch and delete could keep
  // feedback rows or storage keys alive after the entry is removed.
  const artifacts = await findEntryArtifactsForCascade(tx, entryId);
  const storageKeys = storageDeletionJobsForArtifacts(artifacts);
  await queueEntryStorageDeletionJobs(tx, entryId, storageKeys);
  await deleteEntryArtifacts(tx, artifacts);

  await deleteFeedbackCascade(tx, [entryId], 'entry');
  await tx.deletedEntryTombstone.upsert({
    where: { id: entryId },
    create: { id: entryId },
    update: {},
  });
  await tx.practiceEntry.delete({ where: { id: entryId } });
  return storageKeys.map(({ storageKey }) => storageKey);
}

type ArtifactForCascade = {
  id: string;
  storageKey: string | null;
  uploadSessions?: CascadeArtifactUploadSession[];
};

type CascadeArtifactUploadSession = {
  storageKey: string;
  expiresAt: Date;
  credentialExpiresAt: Date | null;
  completionFinalKey: string | null;
  completionClaimedAt: Date | null;
  completedAt: Date | null;
};

type StorageDeletionJob = { storageKey: string; nextAttemptAt: Date };

async function findEntryArtifactsForCascade(tx: EntryTransaction, entryId: string) {
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

function storageDeletionJobsForArtifacts(artifacts: ArtifactForCascade[]): StorageDeletionJob[] {
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
  artifact: ArtifactForCascade
) {
  addStorageDeletionCandidate(cleanupByKey, artifact.storageKey, new Date());
  for (const session of artifact.uploadSessions ?? []) {
    addUploadSessionStorageDeletionCandidates(cleanupByKey, session);
  }
}

function addUploadSessionStorageDeletionCandidates(
  cleanupByKey: Map<string, Date>,
  session: CascadeArtifactUploadSession
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
  tx: EntryTransaction,
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

async function deleteEntryArtifacts(tx: EntryTransaction, artifacts: ArtifactForCascade[]) {
  const artifactIds = artifacts.map((artifact) => artifact.id);
  if (artifactIds.length === 0) return;
  await deleteFeedbackCascade(tx, artifactIds);
  await tx.artifact.deleteMany({ where: { id: { in: artifactIds } } });
}

/**
 * Delete all feedback and markers for the given target IDs.
 * Default targetType is 'artifact'; pass 'entry' for entry-level feedback.
 */
async function deleteFeedbackCascade(
  tx: EntryTransaction,
  targetIds: string[],
  targetType: FeedbackTargetType = 'artifact'
) {
  if (targetIds.length === 0) return;

  const feedback = await tx.feedback.findMany({
    where: { targetType, targetId: { in: targetIds } },
    select: { id: true },
  });
  const feedbackIds = feedback.map((feedback) => feedback.id);
  if (feedbackIds.length > 0) {
    await tx.marker.deleteMany({ where: { feedbackId: { in: feedbackIds } } });
    await tx.feedback.deleteMany({ where: { id: { in: feedbackIds } } });
  }
}
