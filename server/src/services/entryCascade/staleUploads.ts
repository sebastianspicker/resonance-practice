import type { PrismaClient } from '@prisma/client';
import {
  artifactSessionCleanupAt,
  type EntryTransaction,
  queueStorageDeletion,
} from '../entryTransaction.js';
import {
  isCandidateArtifactInState,
  lockAndFindArtifact,
  type ArtifactCandidate,
  type LockedArtifact,
  incrementEntryVersion,
} from './artifactTransaction.js';
import { resolveCleanupOptions, type CleanupOptions } from './shared.js';

const STAGING_CLEANUP_GRACE_MS = 5 * 60_000;

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
  return expireStaleArtifactCandidates(prisma, now, limit);
}

async function expireStaleArtifactCandidates(prisma: PrismaClient, now: Date, limit: number) {
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
  candidate: ArtifactCandidate,
  now: Date
): Promise<number> {
  const artifact = await lockAndFindArtifact(tx, candidate);
  if (!artifact) return 0;
  if (!isExpiredUploadingArtifact(artifact, candidate, now)) return 0;
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
  await queueAbandonedArtifactKeys({
    tx,
    entryId: candidate.entryId,
    artifactStorageKey: artifact.storageKey,
    sessions,
    cleanupAt,
  });
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
  await incrementEntryVersion(tx, candidate.entryId);
  return 1;
}

function isExpiredUploadingArtifact(
  artifact: LockedArtifact,
  candidate: ArtifactCandidate,
  now: Date
) {
  if (!isCandidateArtifactInState(artifact, candidate, 'uploading')) return false;
  return artifact.uploadExpiresAt === null || artifact.uploadExpiresAt <= now;
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

type AbandonedArtifactCleanup = {
  tx: EntryTransaction;
  entryId: string;
  artifactStorageKey: string | null;
  sessions: AbandonedArtifactSession[];
  cleanupAt: Date;
};

async function queueAbandonedArtifactKeys({
  tx,
  entryId,
  artifactStorageKey,
  sessions,
  cleanupAt,
}: AbandonedArtifactCleanup) {
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
