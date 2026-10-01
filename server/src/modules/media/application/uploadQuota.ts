/** Per-user and per-entry artifact upload quotas, admitted under a per-user lock. */
import type { Prisma } from '@prisma/client';
import {
  advisoryTransactionLock,
  AdvisoryLockNamespace,
} from '../../../platform/database/advisoryLocks.js';
import { ErrorCodes } from '../../../platform/http/errorCodes.js';
import { ApiError } from '../../../platform/http/errors.js';

const MAX_ACTIVE_ARTIFACT_SESSIONS_PER_USER = 24;
const MAX_ACTIVE_ARTIFACT_SESSIONS_PER_ENTRY = 8;
const MAX_TOTAL_ARTIFACTS_PER_USER = 500;
const MAX_TOTAL_ARTIFACT_BYTES_PER_USER = 10 * 1024 * 1024 * 1024;

/** Serialize durable artifact quota admission for one user. */
export async function lockArtifactQuotaIdentity(
  tx: Prisma.TransactionClient,
  userId: string
): Promise<void> {
  await advisoryTransactionLock(tx, userId, AdvisoryLockNamespace.userQuota);
}

export async function assertArtifactSessionCapacity(
  tx: Prisma.TransactionClient,
  userId: string,
  entryId: string,
  sizeBytes: number,
  now: Date
) {
  const [activeForUser, activeForEntry, durableUsage] = await Promise.all([
    tx.artifactUploadSession.count({
      where: { userId, completedAt: null, expiresAt: { gt: now } },
    }),
    tx.artifactUploadSession.count({
      where: { artifact: { entryId }, completedAt: null, expiresAt: { gt: now } },
    }),
    tx.artifact.aggregate({
      where: { entry: { studentId: userId } },
      _count: { _all: true },
      _sum: { expectedSizeBytes: true },
    }),
  ]);
  if (
    activeForUser >= MAX_ACTIVE_ARTIFACT_SESSIONS_PER_USER ||
    activeForEntry >= MAX_ACTIVE_ARTIFACT_SESSIONS_PER_ENTRY
  ) {
    throw new ApiError(429, ErrorCodes.RATE_LIMITED, 'Too many active artifact upload sessions');
  }
  if (
    durableUsage._count._all >= MAX_TOTAL_ARTIFACTS_PER_USER ||
    (durableUsage._sum.expectedSizeBytes ?? 0) + sizeBytes > MAX_TOTAL_ARTIFACT_BYTES_PER_USER
  ) {
    throw new ApiError(
      429,
      ErrorCodes.RATE_LIMITED,
      'Artifact storage quota reached; remove old artifacts before uploading more'
    );
  }
}
