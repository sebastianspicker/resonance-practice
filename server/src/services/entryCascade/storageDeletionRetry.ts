import type { S3Client } from '@aws-sdk/client-s3';
import { DeleteObjectCommand } from '@aws-sdk/client-s3';
import type { PrismaClient } from '@prisma/client';
import { config } from '../../config.js';
import { withDeadline } from '../deadline.js';
import { boundedStorageDeletionLimit } from './shared.js';

const MAX_STORAGE_DELETION_ERROR_LENGTH = 1000;
const STORAGE_DELETION_RETRY_BASE_MS = 60_000;
const STORAGE_DELETION_RETRY_MAX_MS = 60 * 60_000;

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
  const jobs = await prisma.storageDeletionJob.findMany({
    where: {
      nextAttemptAt: { lte: now },
      ...(options.entryId ? { entryId: options.entryId } : {}),
    },
    orderBy: [{ nextAttemptAt: 'asc' }, { createdAt: 'asc' }],
    take: limit,
  });

  const context = { prisma, s3, logger, now, requestTimeoutMs };
  for (const job of jobs) {
    await retryStorageDeletionJob(context, job);
  }

  return jobs.length;
}

type StorageDeletionJobRecord = { id: string; storageKey: string; attemptCount: number };

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
    // deleteMany is idempotent when an on-demand run and the periodic worker
    // process the same job concurrently.
    await context.prisma.storageDeletionJob.deleteMany({ where: { id: job.id } });
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
      where: { id: job.id },
      data: {
        attemptCount: { increment: 1 },
        lastError: describeStorageDeletionError(err),
        nextAttemptAt: new Date(
          context.now.getTime() + storageDeletionRetryDelayMs(job.attemptCount)
        ),
      },
    });
  } catch (updateErr) {
    context.logger.error(
      { err: updateErr, jobId: job.id },
      'Failed to record queued S3 deletion failure'
    );
  }
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
