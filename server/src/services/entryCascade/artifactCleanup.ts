import type { PrismaClient } from '@prisma/client';
import { ErrorCodes } from '../../errorCodes.js';
import { ApiError } from '../../errors.js';
import { isS3NotFoundError } from '../../storage.js';
import type { EntryTransaction } from '../entryTransaction.js';
import {
  isCandidateArtifactInState,
  lockAndFindArtifact,
  type ArtifactCandidate,
  type LockedArtifact,
  incrementEntryVersion,
} from './artifactTransaction.js';
import { resolveCleanupOptions, type CleanupOptions } from './shared.js';

const COMPLETED_SESSION_RETENTION_MS = 7 * 24 * 60 * 60_000;
const FAILED_ARTIFACT_RETENTION_MS = 7 * 24 * 60 * 60_000;

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
  const failedBefore = new Date(now.getTime() - FAILED_ARTIFACT_RETENTION_MS);
  const candidates = await prisma.artifact.findMany({
    where: {
      uploadState: 'failed',
      failedAt: { lte: failedBefore },
    },
    select: { id: true, entryId: true },
    orderBy: { failedAt: 'asc' },
    take: limit,
  });
  let deletedCount = 0;
  for (const candidate of candidates) {
    deletedCount += await transactionOrMissingEntry(prisma, (tx) =>
      cleanupFailedArtifactCandidate(tx, candidate, failedBefore)
    );
  }
  return deletedCount;
}

async function transactionOrMissingEntry(
  prisma: PrismaClient,
  operation: (tx: EntryTransaction) => Promise<number>
): Promise<number> {
  try {
    return await prisma.$transaction(operation);
  } catch (error) {
    if (isMissingEntryError(error)) return 0;
    throw error;
  }
}

async function cleanupFailedArtifactCandidate(
  tx: EntryTransaction,
  candidate: ArtifactCandidate,
  failedBefore: Date
): Promise<number> {
  const artifact = await lockAndFindArtifact(tx, candidate);
  if (!artifact) return 0;
  if (!isRetainedFailedArtifact(artifact, candidate, failedBefore)) return 0;

  await tx.artifact.delete({ where: { id: artifact.id } });
  await incrementEntryVersion(tx, candidate.entryId);
  return 1;
}

function isRetainedFailedArtifact(
  artifact: LockedArtifact,
  candidate: ArtifactCandidate,
  failedBefore: Date
) {
  if (!isCandidateArtifactInState(artifact, candidate, 'failed')) return false;
  if (!artifact.failedAt) return false;
  return artifact.failedAt <= failedBefore;
}

function isMissingEntryError(error: unknown) {
  return error instanceof ApiError && error.code === ErrorCodes.ENTRY_NOT_FOUND;
}
