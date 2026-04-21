import type { S3Client } from '@aws-sdk/client-s3';
import { DeleteObjectCommand } from '@aws-sdk/client-s3';
import type { PrismaClient, FeedbackTargetType } from '@prisma/client';
import { config } from '../config.js';
import { ErrorCodes } from '../errorCodes.js';
import { ApiError, isPrismaError } from '../errors.js';

/**
 * Delete an entry and all associated data (artifacts, feedback, markers)
 * in a single transaction. Returns storage keys for subsequent S3 cleanup.
 */
export async function cascadeDeleteEntry(prisma: PrismaClient, entryId: string): Promise<string[]> {
  try {
    const storageKeys = await prisma.$transaction(async (tx) => {
      // Artifact enumeration is now inside the transaction to prevent race
      // conditions where artifacts could be added between the prefetch and
      // the cascade deletes (fixes bug #20).
      const artifacts = await tx.artifact.findMany({
        where: { entryId },
        select: { id: true, storageKey: true },
      });
      const keys = artifacts.map((a) => a.storageKey).filter((key): key is string => key !== null);

      const artifactIds = artifacts.map((a) => a.id);
      if (artifactIds.length > 0) {
        await deleteFeedbackCascade(tx, artifactIds);
        await tx.artifact.deleteMany({ where: { id: { in: artifactIds } } });
      }

      await deleteFeedbackCascade(tx, [entryId], 'entry');
      await tx.practiceEntry.update({ where: { id: entryId }, data: { deletedAt: new Date() } });

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
 * Delete S3 objects for the given storage keys.
 * Logs failures but does not throw — orphaned objects can be cleaned up later.
 */
export async function cleanupS3Objects(
  s3: S3Client,
  storageKeys: string[],
  logger: { error: (obj: object, msg: string) => void }
) {
  for (const storageKey of storageKeys) {
    try {
      await s3.send(new DeleteObjectCommand({ Bucket: config.s3.bucket, Key: storageKey }));
    } catch (err) {
      logger.error({ err, storageKey }, 'Failed to delete S3 object after entry deletion');
    }
  }
}
