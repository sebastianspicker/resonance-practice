import type { S3Client } from '@aws-sdk/client-s3';
import { DeleteObjectCommand } from '@aws-sdk/client-s3';
import { Prisma, type PrismaClient } from '@prisma/client';
import { nanoid } from 'nanoid';
import { config } from '../../../../platform/config.js';
import { withDeadline } from '../../../../platform/deadline.js';
import { boundedStorageDeletionLimit } from '../cleanup/shared.js';

const MAX_STORAGE_DELETION_ERROR_LENGTH = 1000;
const STORAGE_DELETION_RETRY_BASE_MS = 60_000;
const STORAGE_DELETION_RETRY_MAX_MS = 60 * 60_000;
const STORAGE_DELETION_CLAIM_SETTLEMENT_MS = 5_000;

type ErrorLogger = {
  error: (obj: object, msg: string) => void;
};

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
  const limit = boundedStorageDeletionLimit(options.limit);
  const requestTimeoutMs = options.requestTimeoutMs ?? config.dependencyTimeoutMs;
  const context = { prisma, s3, logger, now, requestTimeoutMs };
  let processed = 0;
  while (processed < limit) {
    const job = await claimNextStorageDeletionJob(prisma, options.entryId, now, requestTimeoutMs);
    if (!job) break;
    await retryStorageDeletionJob(context, job);
    processed += 1;
  }
  return processed;
}

type StorageDeletionJobRecord = {
  id: string;
  storageKey: string;
  attemptCount: number;
  claimToken: string;
};

type StorageDeletionRetryContext = {
  prisma: PrismaClient;
  s3: S3Client;
  logger: ErrorLogger;
  now: Date;
  requestTimeoutMs: number;
};

async function retryStorageDeletionJob(
  context: StorageDeletionRetryContext,
  job: StorageDeletionJobRecord
) {
  try {
    await withDeadline(
      (abortSignal) =>
        context.s3.send(
          new DeleteObjectCommand({ Bucket: config.s3.bucket, Key: job.storageKey }),
          {
            abortSignal,
          }
        ),
      context.requestTimeoutMs,
      'S3 DeleteObject'
    );
  } catch (err) {
    await recordStorageDeletionFailure(context, job, err);
    context.logger.error(
      { err, storageKey: job.storageKey, jobId: job.id },
      'Failed to delete queued S3 object'
    );
    return;
  }

  try {
    await context.prisma.storageDeletionJob.deleteMany({
      where: { id: job.id, claimToken: job.claimToken },
    });
  } catch (err) {
    context.logger.error(
      { err, storageKey: job.storageKey, jobId: job.id },
      'Deleted S3 object but failed to remove its cleanup job'
    );
  }
}

async function recordStorageDeletionFailure(
  context: StorageDeletionRetryContext,
  job: StorageDeletionJobRecord,
  err: unknown
) {
  try {
    await context.prisma.storageDeletionJob.updateMany({
      where: { id: job.id, claimToken: job.claimToken },
      data: {
        attemptCount: { increment: 1 },
        lastError: describeStorageDeletionError(err),
        nextAttemptAt: new Date(
          context.now.getTime() + storageDeletionRetryDelayMs(job.attemptCount)
        ),
        claimToken: null,
        claimExpiresAt: null,
      },
    });
  } catch (updateErr) {
    context.logger.error(
      { err: updateErr, jobId: job.id },
      'Failed to record queued S3 deletion failure'
    );
  }
}

/** Atomically claim one due job immediately before its storage request. */
async function claimNextStorageDeletionJob(
  prisma: PrismaClient,
  entryId: string | undefined,
  dueAt: Date,
  requestTimeoutMs: number
): Promise<StorageDeletionJobRecord | null> {
  const claimToken = nanoid(24);
  const claimedAt = new Date();
  const claimExpiresAt = new Date(
    claimedAt.getTime() + requestTimeoutMs + STORAGE_DELETION_CLAIM_SETTLEMENT_MS
  );
  const entryFilter = entryId ? Prisma.sql`AND "entryId" = ${entryId}` : Prisma.empty;
  const claimed = await prisma.$queryRaw<StorageDeletionJobRecord[]>(Prisma.sql`
    UPDATE "StorageDeletionJob" AS job
    SET "claimToken" = ${claimToken},
        "claimExpiresAt" = ${claimExpiresAt},
        "updatedAt" = ${claimedAt}
    FROM (
      SELECT "id"
      FROM "StorageDeletionJob"
      WHERE "nextAttemptAt" <= ${dueAt}
        AND ("claimExpiresAt" IS NULL OR "claimExpiresAt" <= ${claimedAt})
        ${entryFilter}
      ORDER BY "nextAttemptAt" ASC, "createdAt" ASC
      FOR UPDATE SKIP LOCKED
      LIMIT 1
    ) AS candidate
    WHERE job."id" = candidate."id"
    RETURNING job."id", job."storageKey", job."attemptCount", job."claimToken"
  `);
  return claimed[0] ?? null;
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
