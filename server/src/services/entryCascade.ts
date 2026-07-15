import type { S3Client } from '@aws-sdk/client-s3';
import { DeleteObjectCommand } from '@aws-sdk/client-s3';
import type { PrismaClient, FeedbackTargetType } from '@prisma/client';
import { config } from '../config.js';
import { ErrorCodes } from '../errorCodes.js';
import { ApiError, isPrismaError } from '../errors.js';
import { lockEntry, lockEntryIdentity } from './entryTransaction.js';
import { withDeadline } from './deadline.js';

const MAX_STORAGE_DELETION_ERROR_LENGTH = 1000;
const DEFAULT_STORAGE_DELETION_BATCH_SIZE = 100;
const MAX_STORAGE_DELETION_BATCH_SIZE = 1000;
const STORAGE_DELETION_RETRY_BASE_MS = 60_000;
const STORAGE_DELETION_RETRY_MAX_MS = 60 * 60_000;

type ErrorLogger = {
  error: (obj: object, msg: string) => void;
};

/**
 * Retire expired presigned-upload slots in bounded batches. The old key is
 * queued before the artifact forgets it, so abandoned objects are eventually
 * removed without risking deletion of a newer upload attempt.
 */
export async function expireStaleArtifactUploads(
  prisma: PrismaClient,
  options: { limit?: number; now?: Date } = {}
): Promise<number> {
  const now = options.now ?? new Date();
  const limit = Math.min(
    Math.max(options.limit ?? DEFAULT_STORAGE_DELETION_BATCH_SIZE, 1),
    MAX_STORAGE_DELETION_BATCH_SIZE
  );
  const candidates = await prisma.artifact.findMany({
    where: {
      uploadState: 'uploading',
      OR: [{ uploadExpiresAt: null }, { uploadExpiresAt: { lte: now } }],
    },
    select: { id: true, entryId: true },
    orderBy: { uploadExpiresAt: 'asc' },
    take: limit,
  });
  let expiredCount = 0;

  for (const candidate of candidates) {
    await prisma.$transaction(async (tx) => {
      await lockEntry(tx, candidate.entryId);
      const artifact = await tx.artifact.findUnique({ where: { id: candidate.id } });
      if (
        !artifact ||
        artifact.entryId !== candidate.entryId ||
        artifact.uploadState !== 'uploading' ||
        (artifact.uploadExpiresAt !== null && artifact.uploadExpiresAt > now)
      ) {
        return;
      }

      if (artifact.storageKey) {
        await tx.storageDeletionJob.upsert({
          where: { storageKey: artifact.storageKey },
          create: { entryId: candidate.entryId, storageKey: artifact.storageKey },
          update: {},
        });
      }
      await tx.artifact.update({
        where: { id: artifact.id },
        data: {
          uploadState: 'failed',
          storageKey: null,
          remoteUrl: null,
          uploadExpiresAt: null,
          confirmationToken: null,
        },
      });
      expiredCount += 1;
    });
  }

  return expiredCount;
}

/**
 * Hard-delete an entry and its associated data in one transaction, retaining
 * only a minimal ID tombstone to prevent stale offline work from reusing the
 * identifier. Storage keys are durably queued before artifact rows disappear.
 */
export async function cascadeDeleteEntry(prisma: PrismaClient, entryId: string): Promise<string[]> {
  try {
    const storageKeys = await prisma.$transaction(async (tx) => {
      // The advisory ID lock prevents a concurrent create from reusing this ID
      // after the row is deleted but before its tombstone is committed.
      await lockEntryIdentity(tx, entryId);
      const entry = await lockEntry(tx, entryId);
      if (entry.deletedAt) {
        throw new ApiError(410, ErrorCodes.ENTRY_DELETED, 'Entry has been deleted');
      }

      // Keep artifact enumeration inside the same transaction as the cascade.
      // Otherwise an artifact created between prefetch and delete could keep
      // feedback rows or storage keys alive after the entry is marked deleted.
      const artifacts = await tx.artifact.findMany({
        where: { entryId },
        select: { id: true, storageKey: true },
      });
      const keys = artifacts.map((a) => a.storageKey).filter((key): key is string => key !== null);

      if (keys.length > 0) {
        await tx.storageDeletionJob.createMany({
          data: keys.map((storageKey) => ({ entryId, storageKey })),
          skipDuplicates: true,
        });
      }

      const artifactIds = artifacts.map((a) => a.id);
      if (artifactIds.length > 0) {
        await deleteFeedbackCascade(tx, artifactIds);
        await tx.artifact.deleteMany({ where: { id: { in: artifactIds } } });
      }

      await deleteFeedbackCascade(tx, [entryId], 'entry');

      await tx.deletedEntryTombstone.upsert({
        where: { id: entryId },
        create: { id: entryId },
        update: {},
      });
      await tx.practiceEntry.delete({ where: { id: entryId } });

      return keys;
    });

    return storageKeys;
  } catch (err: unknown) {
    if (isPrismaError(err, 'P2025')) {
      throw new ApiError(404, ErrorCodes.ENTRY_NOT_FOUND, 'Entry not found');
    }
    throw err;
  }
}

/**
 * Delete all feedback and markers for the given target IDs.
 * Default targetType is 'artifact'; pass 'entry' for entry-level feedback.
 */
async function deleteFeedbackCascade(
  tx: Parameters<Parameters<PrismaClient['$transaction']>[0]>[0],
  targetIds: string[],
  targetType: FeedbackTargetType = 'artifact'
) {
  if (targetIds.length === 0) return;

  const feedback = await tx.feedback.findMany({
    where: { targetType, targetId: { in: targetIds } },
    select: { id: true },
  });
  const feedbackIds = feedback.map((f) => f.id);
  if (feedbackIds.length > 0) {
    await tx.marker.deleteMany({ where: { feedbackId: { in: feedbackIds } } });
    await tx.feedback.deleteMany({ where: { id: { in: feedbackIds } } });
  }
}

/**
 * Process durable S3 deletion jobs. Successful deletes remove their job;
 * failures are retained for a later retry with bounded diagnostic context.
 */
export async function retryStorageDeletionJobs(
  prisma: PrismaClient,
  s3: S3Client,
  logger: ErrorLogger,
  options: { entryId?: string; limit?: number; now?: Date; requestTimeoutMs?: number } = {}
): Promise<number> {
  const now = options.now ?? new Date();
  const limit = Math.min(
    Math.max(options.limit ?? DEFAULT_STORAGE_DELETION_BATCH_SIZE, 1),
    MAX_STORAGE_DELETION_BATCH_SIZE
  );
  const requestTimeoutMs = options.requestTimeoutMs ?? config.dependencyTimeoutMs;
  const jobs = await prisma.storageDeletionJob.findMany({
    where: {
      nextAttemptAt: { lte: now },
      ...(options.entryId ? { entryId: options.entryId } : {}),
    },
    orderBy: [{ nextAttemptAt: 'asc' }, { createdAt: 'asc' }],
    take: limit,
  });

  for (const job of jobs) {
    try {
      await withDeadline(
        (abortSignal) =>
          s3.send(new DeleteObjectCommand({ Bucket: config.s3.bucket, Key: job.storageKey }), {
            abortSignal,
          }),
        requestTimeoutMs,
        'S3 DeleteObject'
      );
    } catch (err) {
      try {
        await prisma.storageDeletionJob.updateMany({
          where: { id: job.id },
          data: {
            attemptCount: { increment: 1 },
            lastError: describeStorageDeletionError(err),
            nextAttemptAt: new Date(now.getTime() + storageDeletionRetryDelayMs(job.attemptCount)),
          },
        });
      } catch (updateErr) {
        logger.error(
          { err: updateErr, jobId: job.id },
          'Failed to record queued S3 deletion failure'
        );
      }
      logger.error(
        { err, storageKey: job.storageKey, jobId: job.id },
        'Failed to delete queued S3 object'
      );
      continue;
    }

    try {
      // deleteMany is idempotent when an on-demand run and the periodic worker
      // process the same job concurrently.
      await prisma.storageDeletionJob.deleteMany({ where: { id: job.id } });
    } catch (err) {
      logger.error(
        { err, storageKey: job.storageKey, jobId: job.id },
        'Deleted S3 object but failed to remove its cleanup job'
      );
    }
  }

  return jobs.length;
}

function describeStorageDeletionError(err: unknown): string {
  const message = err instanceof Error ? err.message : String(err);
  return message.slice(0, MAX_STORAGE_DELETION_ERROR_LENGTH);
}

function storageDeletionRetryDelayMs(attemptCount: number): number {
  return Math.min(
    STORAGE_DELETION_RETRY_BASE_MS * 2 ** Math.min(Math.max(attemptCount, 0), 6),
    STORAGE_DELETION_RETRY_MAX_MS
  );
}
