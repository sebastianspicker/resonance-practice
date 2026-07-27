/** Entry deletion cascades plus retryable remote-artifact cleanup. */
import type { S3Client } from '@aws-sdk/client-s3';
import { DeleteObjectCommand } from '@aws-sdk/client-s3';
import type { PrismaClient, FeedbackTargetType } from '@prisma/client';
import { config } from '../config.js';
import { ErrorCodes } from '../errorCodes.js';
import { ApiError, isPrismaError } from '../errors.js';
import { isS3NotFoundError } from '../storage.js';
import {
  artifactSessionCleanupAt,
  type EntryTransaction,
  lockEntry,
  lockEntryIdentity,
  queueStorageDeletion,
} from './entryTransaction.js';
import { withDeadline } from './deadline.js';

const MAX_STORAGE_DELETION_ERROR_LENGTH = 1000;
const DEFAULT_STORAGE_DELETION_BATCH_SIZE = 100;
const MAX_STORAGE_DELETION_BATCH_SIZE = 1000;
const STORAGE_DELETION_RETRY_BASE_MS = 60_000;
const STORAGE_DELETION_RETRY_MAX_MS = 60 * 60_000;
const STAGING_CLEANUP_GRACE_MS = 5 * 60_000;
const COMPLETED_SESSION_RETENTION_MS = 7 * 24 * 60 * 60_000;
const FAILED_ARTIFACT_RETENTION_MS = 7 * 24 * 60 * 60_000;

type ErrorLogger = {
  error: (obj: object, msg: string) => void;
};

type CleanupOptions = { limit?: number; now?: Date };

function resolveCleanupOptions(options: CleanupOptions) {
  return {
    now: options.now ?? new Date(),
    limit: Math.min(
      Math.max(options.limit ?? DEFAULT_STORAGE_DELETION_BATCH_SIZE, 1),
      MAX_STORAGE_DELETION_BATCH_SIZE
    ),
  };
}

async function lockAndFindArtifact(
  tx: EntryTransaction,
  candidate: { id: string; entryId: string }
) {
  await lockEntry(tx, candidate.entryId);
  return tx.artifact.findUnique({ where: { id: candidate.id } });
}

export function isS3SourceInvalidError(error: unknown) {
  if (isS3NotFoundError(error)) return true;
  if (typeof error !== 'object' || error === null) return false;
  const storageError = error as {
    name?: string;
    $metadata?: { httpStatusCode?: number };
  };
  return (
    storageError.name === 'PreconditionFailed' ||
    storageError.name === 'ConditionalRequestConflict' ||
    storageError.$metadata?.httpStatusCode === 412
  );
}

/** Retain completion receipts briefly for idempotency, then prune in batches. */
export async function cleanupCompletedArtifactSessions(
  prisma: PrismaClient,
  options: CleanupOptions = {}
): Promise<number> {
  const { now, limit } = resolveCleanupOptions(options);
  const sessions = await prisma.artifactUploadSession.findMany({
    where: { completedAt: { lte: new Date(now.getTime() - COMPLETED_SESSION_RETENTION_MS) } },
    select: { id: true },
    orderBy: { completedAt: 'asc' },
    take: limit,
  });
  if (sessions.length === 0) return 0;
  await prisma.artifactUploadSession.deleteMany({
    where: { id: { in: sessions.map((session) => session.id) } },
  });
  return sessions.length;
}

/** Retain failed placeholders for retry diagnostics, then reclaim their quota. */
export async function cleanupFailedArtifacts(
  prisma: PrismaClient,
  options: CleanupOptions = {}
): Promise<number> {
  const { now, limit } = resolveCleanupOptions(options);
  const candidates = await prisma.artifact.findMany({
    where: {
      uploadState: 'failed',
      failedAt: { lte: new Date(now.getTime() - FAILED_ARTIFACT_RETENTION_MS) },
    },
    select: { id: true, entryId: true },
    orderBy: { failedAt: 'asc' },
    take: limit,
  });
  let deletedCount = 0;
  for (const candidate of candidates) {
    try {
      await prisma.$transaction(async (tx) => {
        const artifact = await lockAndFindArtifact(tx, candidate);
        if (
          !artifact ||
          artifact.entryId !== candidate.entryId ||
          artifact.uploadState !== 'failed' ||
          !artifact.failedAt ||
          artifact.failedAt > new Date(now.getTime() - FAILED_ARTIFACT_RETENTION_MS)
        ) {
          return;
        }
        await tx.artifact.delete({ where: { id: artifact.id } });
        await tx.practiceEntry.update({
          where: { id: candidate.entryId },
          data: { version: { increment: 1 } },
        });
        deletedCount += 1;
      });
    } catch (error) {
      if (error instanceof ApiError && error.code === ErrorCodes.ENTRY_NOT_FOUND) continue;
      throw error;
    }
  }
  return deletedCount;
}

/**
 * Retire expired presigned-upload slots in bounded batches. The old key is
 * queued before the artifact forgets it, so abandoned objects are eventually
 * removed without risking deletion of a newer upload attempt.
 */
export async function expireStaleArtifactUploads(
  prisma: PrismaClient,
  options: CleanupOptions = {}
): Promise<number> {
  const { now, limit } = resolveCleanupOptions(options);
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
    expiredCount += await prisma.$transaction((tx) =>
      expireStaleArtifactCandidate(tx, candidate, now)
    );
  }
  return expiredCount;
}

async function expireStaleArtifactCandidate(
  tx: EntryTransaction,
  candidate: { id: string; entryId: string },
  now: Date
): Promise<number> {
  const artifact = await lockAndFindArtifact(tx, candidate);
  if (
    !artifact ||
    artifact.entryId !== candidate.entryId ||
    artifact.uploadState !== 'uploading' ||
    (artifact.uploadExpiresAt !== null && artifact.uploadExpiresAt > now)
  ) {
    return 0;
  }
  const sessions = await tx.artifactUploadSession.findMany({
    where: { artifactId: artifact.id, completedAt: null },
    select: {
      storageKey: true,
      expiresAt: true,
      credentialExpiresAt: true,
      completionFinalKey: true,
      completionClaimedAt: true,
    },
  });
  const cleanupAt = latestArtifactCleanupAt(artifact, sessions);
  await queueAbandonedArtifactKeys(tx, candidate.entryId, artifact.storageKey, sessions, cleanupAt);
  if (cleanupAt > now) return 0;
  await tx.artifact.update({
    where: { id: artifact.id },
    data: {
      uploadState: 'failed',
      storageKey: null,
      remoteUrl: null,
      uploadExpiresAt: null,
      confirmationToken: null,
      failedAt: now,
    },
  });
  await tx.artifactUploadSession.deleteMany({
    where: { artifactId: artifact.id, completedAt: null, expiresAt: { lte: now } },
  });
  await tx.practiceEntry.update({
    where: { id: candidate.entryId },
    data: { version: { increment: 1 } },
  });
  return 1;
}

type AbandonedArtifactSession = {
  storageKey: string;
  expiresAt: Date;
  credentialExpiresAt: Date | null;
  completionFinalKey: string | null;
  completionClaimedAt: Date | null;
};

function latestArtifactCleanupAt(
  artifact: { uploadExpiresAt: Date | null; createdAt: Date },
  sessions: AbandonedArtifactSession[]
) {
  return sessions.reduce(
    (latest, session) => {
      const sessionCleanupAt = artifactSessionCleanupAt(session);
      return sessionCleanupAt > latest ? sessionCleanupAt : latest;
    },
    new Date((artifact.uploadExpiresAt ?? artifact.createdAt).getTime() + STAGING_CLEANUP_GRACE_MS)
  );
}

async function queueAbandonedArtifactKeys(
  tx: EntryTransaction,
  entryId: string,
  artifactStorageKey: string | null,
  sessions: AbandonedArtifactSession[],
  cleanupAt: Date
) {
  if (artifactStorageKey) {
    await queueStorageDeletion(tx, entryId, artifactStorageKey, cleanupAt);
  }
  for (const session of sessions) {
    const sessionCleanupAt = artifactSessionCleanupAt(session);
    if (session.storageKey !== artifactStorageKey) {
      await queueStorageDeletion(tx, entryId, session.storageKey, sessionCleanupAt);
    }
    if (session.completionFinalKey) {
      await queueStorageDeletion(tx, entryId, session.completionFinalKey, sessionCleanupAt);
    }
  }
}

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
  const artifacts = await tx.artifact.findMany({
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
  const cleanupCandidates = artifacts.flatMap((artifact) => [
    ...(artifact.storageKey
      ? [{ storageKey: artifact.storageKey, nextAttemptAt: new Date() }]
      : []),
    ...(artifact.uploadSessions ?? []).map((session) => ({
      storageKey: session.storageKey,
      // A valid client PUT may arrive after this deletion transaction. Keep
      // the durable cleanup job dormant until every issued URL and bounded
      // completion claim has expired plus grace.
      nextAttemptAt: artifactSessionCleanupAt(session),
    })),
    ...(artifact.uploadSessions ?? [])
      .filter((session) => session.completionFinalKey)
      .map((session) => ({
        storageKey: session.completionFinalKey!,
        nextAttemptAt: session.completedAt ? new Date() : artifactSessionCleanupAt(session),
      })),
  ]);
  // A staging key is present both on Artifact and its upload session. Never
  // let an immediate artifact row override the session's valid-PUT grace.
  const cleanupByKey = new Map<string, Date>();
  for (const candidate of cleanupCandidates) {
    const previous = cleanupByKey.get(candidate.storageKey);
    if (!previous || candidate.nextAttemptAt > previous) {
      cleanupByKey.set(candidate.storageKey, candidate.nextAttemptAt);
    }
  }
  const storageKeys = [...cleanupByKey].map(([storageKey, nextAttemptAt]) => ({
    storageKey,
    nextAttemptAt,
  }));

  if (storageKeys.length > 0) {
    await tx.storageDeletionJob.createMany({
      data: storageKeys.map(({ storageKey, nextAttemptAt }) => ({
        entryId,
        storageKey,
        nextAttemptAt,
      })),
      skipDuplicates: true,
    });
  }

  const artifactIds = artifacts.map((artifact) => artifact.id);
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
  return storageKeys.map(({ storageKey }) => storageKey);
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
