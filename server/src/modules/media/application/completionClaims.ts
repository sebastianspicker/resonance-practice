/** Locked completion-claim lifecycle for one durable artifact upload session. */
import type { ArtifactType, Prisma, PrismaClient } from '@prisma/client';
import { nanoid } from 'nanoid';
import {
  advisoryTransactionLock,
  AdvisoryLockNamespace,
} from '../../../platform/database/advisoryLocks.js';
import { ErrorCodes } from '../../../platform/http/errorCodes.js';
import { ApiError } from '../../../platform/http/errors.js';
import { requireStudentOwner } from '../../entries/application/authorization.js';
import { assertEntryActive, lockEntry } from '../../entries/application/locks.js';
import { bumpEntryVersion } from '../../entries/application/versionConflict.js';
import { artifactFinalKey } from './artifactIdentity.js';
import { artifactCompletionClaimLeaseEnd } from './completionLease.js';
import { artifactSessionCleanupAt, queueStorageDeletion } from './storageDeletion/schedule.js';

export type ArtifactCompletionClaim = {
  token: string;
  storageKey: string;
  stagingKey: string;
  expectedSizeBytes: number | null;
  checksumSha256: string;
  type: ArtifactType;
  expiresAt: Date;
  credentialExpiresAt: Date | null;
  claimedAt: Date;
  entryId: string;
  artifactId: string;
};

/** Serialize finalization and rotation for one durable upload session. */
export async function lockArtifactSessionIdentity(
  tx: Prisma.TransactionClient,
  sessionId: string
): Promise<void> {
  await advisoryTransactionLock(tx, sessionId, AdvisoryLockNamespace.artifactSession);
}

async function requireArtifactSessionAccess(
  tx: Prisma.TransactionClient,
  userId: string,
  sessionId: string
) {
  await lockArtifactSessionIdentity(tx, sessionId);
  const current = await tx.artifactUploadSession.findUnique({
    where: { id: sessionId },
    include: { artifact: true },
  });
  if (!current || current.userId !== userId) {
    throw new ApiError(404, ErrorCodes.ARTIFACT_NOT_FOUND, 'Artifact session not found');
  }
  const entry = await lockEntry(tx, current.artifact.entryId);
  assertEntryActive(entry);
  await requireStudentOwner(tx, userId, entry, 'upload artifacts');
  return { current, entry };
}

/**
 * Serialize completion and mint a claim-specific final key so stale copiers
 * cannot overwrite a newer successful attempt.
 */
export async function acquireArtifactCompletionClaim(
  prisma: PrismaClient,
  userId: string,
  sessionId: string
) {
  return prisma.$transaction(async (tx) => {
    const { current, entry } = await requireArtifactSessionAccess(tx, userId, sessionId);
    if (current.completedAt) {
      return { completed: true as const, artifact: current.artifact, version: entry.version };
    }
    const now = new Date();
    if (current.expiresAt <= now) {
      throw new ApiError(409, ErrorCodes.UPLOAD_INVALID, 'Artifact session has expired');
    }
    if (
      current.completionClaimToken &&
      artifactCompletionClaimLeaseEnd(current.completionClaimedAt) > now
    ) {
      throw new ApiError(
        409,
        ErrorCodes.UPLOAD_INVALID,
        'Artifact completion is in progress; retry later'
      );
    }
    if (current.completionFinalKey) {
      await queueStorageDeletion(
        tx,
        entry.id,
        current.completionFinalKey,
        artifactSessionCleanupAt(current)
      );
    }
    const token = nanoid(24);
    const storageKey = artifactFinalKey(entry.id, current.artifactId, token);
    await tx.artifactUploadSession.update({
      where: { id: current.id },
      data: {
        completionClaimToken: token,
        completionFinalKey: storageKey,
        completionClaimedAt: now,
      },
    });
    return {
      completed: false as const,
      token,
      storageKey,
      stagingKey: current.storageKey,
      expectedSizeBytes: current.artifact.expectedSizeBytes,
      checksumSha256: current.checksumSha256,
      type: current.artifact.type,
      expiresAt: current.expiresAt,
      credentialExpiresAt: current.credentialExpiresAt,
      claimedAt: now,
      entryId: entry.id,
      artifactId: current.artifactId,
    };
  });
}

/** Abandon only the matching claim and retain its copied key for durable cleanup. */
export async function releaseArtifactCompletionClaim(
  prisma: PrismaClient,
  sessionId: string,
  claim: ArtifactCompletionClaim
) {
  await prisma.$transaction(async (tx) => {
    await lockArtifactSessionIdentity(tx, sessionId);
    const current = await tx.artifactUploadSession.findUnique({ where: { id: sessionId } });
    await queueStorageDeletion(
      tx,
      claim.entryId,
      claim.storageKey,
      artifactSessionCleanupAt({
        expiresAt: claim.expiresAt,
        credentialExpiresAt: claim.credentialExpiresAt,
        completionClaimedAt: claim.claimedAt,
      })
    );
    if (current?.completionClaimToken !== claim.token) return;
    await tx.artifactUploadSession.update({
      where: { id: sessionId },
      data: {
        completionClaimToken: null,
        completionFinalKey: null,
        completionClaimedAt: null,
      },
    });
  });
}

/** Finalization rechecks the claim while locked before publishing the copied key. */
export async function finalizeArtifactCompletionClaim(
  prisma: PrismaClient,
  userId: string,
  sessionId: string,
  claim: ArtifactCompletionClaim
) {
  const finalized = await prisma.$transaction(async (tx) => {
    const { current, entry } = await requireArtifactSessionAccess(tx, userId, sessionId);
    if (current.completedAt) {
      return { expired: false as const, artifact: current.artifact, currentVersion: entry.version };
    }
    if (
      current.completionClaimToken !== claim.token ||
      current.completionFinalKey !== claim.storageKey ||
      current.storageKey !== claim.stagingKey
    ) {
      throw new ApiError(
        409,
        ErrorCodes.UPLOAD_INVALID,
        'Artifact completion claim changed; retry later'
      );
    }
    if (current.expiresAt <= new Date()) {
      await queueStorageDeletion(tx, entry.id, claim.storageKey, artifactSessionCleanupAt(current));
      return { expired: true as const };
    }
    await tx.artifact.update({
      where: { id: claim.artifactId },
      data: {
        storageKey: claim.storageKey,
        uploadState: 'uploaded',
        uploadExpiresAt: null,
        confirmationToken: null,
        failedAt: null,
      },
    });
    await queueStorageDeletion(tx, entry.id, current.storageKey, artifactSessionCleanupAt(current));
    await tx.artifactUploadSession.update({
      where: { id: current.id },
      data: {
        completedAt: new Date(),
        completionClaimToken: null,
        completionClaimedAt: null,
      },
    });
    const updated = await bumpEntryVersion(tx, entry.id);
    const artifact = await tx.artifact.findUniqueOrThrow({ where: { id: current.artifactId } });
    return { expired: false as const, artifact, currentVersion: updated.version };
  });
  if (finalized.expired) {
    throw new ApiError(
      409,
      ErrorCodes.UPLOAD_INVALID,
      'Artifact session expired during finalization'
    );
  }
  return finalized;
}
