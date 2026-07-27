/** Locked entry transactions and PostgreSQL advisory-lock identity helpers. */
import { createHash } from 'node:crypto';
import type { ArtifactType, PracticeEntry, Prisma, PrismaClient } from '@prisma/client';
import { nanoid } from 'nanoid';
import { config } from '../config.js';
import { ErrorCodes } from '../errorCodes.js';
import { ApiError } from '../errors.js';

export type EntryTransaction = Prisma.TransactionClient;

const MAX_ACTIVE_ARTIFACT_SESSIONS_PER_USER = 24;
const MAX_ACTIVE_ARTIFACT_SESSIONS_PER_ENTRY = 8;
const MAX_TOTAL_ARTIFACTS_PER_USER = 500;
const MAX_TOTAL_ARTIFACT_BYTES_PER_USER = 10 * 1024 * 1024 * 1024;
const ARTIFACT_CLEANUP_GRACE_MS = 5 * 60_000;
const COMPLETION_CLAIM_SETTLEMENT_MS = 5_000;

export type ArtifactSessionIdentityInput = {
  entryId: string;
  artifactId: string;
  type: ArtifactType;
  durationSeconds: number;
  sizeBytes: number;
  baseVersion: number;
};

/** Bind an operation ID to the canonical fields that define one upload request. */
export function artifactSessionPayloadHash(value: ArtifactSessionIdentityInput) {
  return createHash('sha256')
    .update(
      JSON.stringify({
        artifactId: value.artifactId,
        entryId: value.entryId,
        type: value.type,
        durationSeconds: value.durationSeconds,
        sizeBytes: value.sizeBytes,
        baseVersion: value.baseVersion,
      })
    )
    .digest('hex');
}

export function artifactStagingKey(entryId: string, artifactId: string) {
  return `artifacts/staging/${entryId}/${artifactId}-${nanoid(16)}`;
}

function artifactFinalKey(entryId: string, artifactId: string, claimToken: string) {
  return `artifacts/final/${entryId}/${artifactId}-${claimToken}`;
}

export async function assertArtifactStudentOwner(
  tx: EntryTransaction,
  userId: string,
  entry: { courseId: string; studentId: string }
) {
  const membership = await tx.membership.findUnique({
    where: { userId_courseId: { userId, courseId: entry.courseId } },
  });
  if (!membership || membership.roleInCourse !== 'student' || entry.studentId !== userId) {
    throw new ApiError(403, ErrorCodes.STUDENT_ONLY, 'Only the student owner can upload artifacts');
  }
}

export function assertEntryActive(entry: { deletedAt: Date | null }) {
  if (entry.deletedAt) {
    throw new ApiError(410, ErrorCodes.ENTRY_DELETED, 'Entry has been deleted');
  }
}

export async function assertArtifactSessionCapacity(
  tx: EntryTransaction,
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

/** Keep a completion claim alive across both bounded storage calls plus settlement. */
export function artifactCompletionClaimLeaseMs() {
  return config.dependencyTimeoutMs * 2 + COMPLETION_CLAIM_SETTLEMENT_MS;
}

/** Return the lease deadline, or the epoch when no claim is active. */
export function artifactCompletionClaimLeaseEnd(claimedAt: Date | null) {
  return claimedAt ? new Date(claimedAt.getTime() + artifactCompletionClaimLeaseMs()) : new Date(0);
}

/** Delay deletion until every issued credential and completion lease is harmless. */
export function artifactSessionCleanupAt(session: {
  expiresAt: Date;
  credentialExpiresAt?: Date | null;
  completionClaimedAt?: Date | null;
}) {
  return new Date(
    Math.max(
      session.expiresAt.getTime(),
      session.credentialExpiresAt?.getTime() ?? 0,
      artifactCompletionClaimLeaseEnd(session.completionClaimedAt ?? null).getTime()
    ) + ARTIFACT_CLEANUP_GRACE_MS
  );
}

/** Upsert one idempotent deletion job without shortening an existing safety delay. */
export async function queueStorageDeletion(
  tx: EntryTransaction,
  entryId: string,
  storageKey: string,
  nextAttemptAt: Date
) {
  const existing = await tx.storageDeletionJob.findUnique({
    where: { storageKey },
    select: { nextAttemptAt: true },
  });
  const safeNextAttemptAt =
    existing && existing.nextAttemptAt > nextAttemptAt ? existing.nextAttemptAt : nextAttemptAt;
  await tx.storageDeletionJob.upsert({
    where: { storageKey },
    create: { entryId, storageKey, nextAttemptAt: safeNextAttemptAt },
    update: { nextAttemptAt: safeNextAttemptAt },
  });
}

export type ArtifactCompletionClaim = {
  token: string;
  storageKey: string;
  stagingKey: string;
  expectedSizeBytes: number | null;
  expiresAt: Date;
  credentialExpiresAt: Date | null;
  claimedAt: Date;
  entryId: string;
  artifactId: string;
};

async function requireArtifactSessionAccess(
  tx: EntryTransaction,
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
  await assertArtifactStudentOwner(tx, userId, entry);
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
    const updated = await tx.practiceEntry.update({
      where: { id: entry.id },
      data: { version: { increment: 1 } },
    });
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

/** Serialize creation and deletion for one client-generated entry ID. */
export async function lockEntryIdentity(tx: EntryTransaction, entryId: string): Promise<void> {
  await tx.$queryRaw<Array<{ locked: string }>>`
    SELECT pg_advisory_xact_lock(hashtextextended(${entryId}, 0))::text AS "locked"
  `;
}

/** Serialize one user's idempotency key before reading or writing its receipt. */
export async function lockOperationIdentity(
  tx: EntryTransaction,
  userId: string,
  operationId: string
): Promise<void> {
  await tx.$queryRaw<Array<{ locked: string }>>`
    SELECT pg_advisory_xact_lock(
      hashtextextended(${`${userId}:${operationId}`}, 1)
    )::text AS "locked"
  `;
}

/** Serialize finalization and rotation for one durable upload session. */
export async function lockArtifactSessionIdentity(
  tx: EntryTransaction,
  sessionId: string
): Promise<void> {
  await tx.$queryRaw<Array<{ locked: string }>>`
    SELECT pg_advisory_xact_lock(hashtextextended(${sessionId}, 2))::text AS "locked"
  `;
}

/** Serialize durable artifact quota admission for one user. */
export async function lockArtifactQuotaIdentity(
  tx: EntryTransaction,
  userId: string
): Promise<void> {
  await tx.$queryRaw<Array<{ locked: string }>>`
    SELECT pg_advisory_xact_lock(hashtextextended(${userId}, 3))::text AS "locked"
  `;
}

/**
 * Serialize state transitions for one practice entry.
 *
 * Child creation, submission, feedback, marker updates, and deletion all use
 * this same parent-row lock so their state checks cannot be invalidated by a
 * concurrent request before the matching write commits.
 */
export async function withLockedEntry<T>(
  prisma: PrismaClient,
  entryId: string,
  operation: (tx: EntryTransaction, entry: PracticeEntry) => Promise<T>
): Promise<T> {
  return prisma.$transaction(async (tx) => {
    const entry = await lockEntry(tx, entryId);
    return operation(tx, entry);
  });
}

export async function lockEntry(tx: EntryTransaction, entryId: string): Promise<PracticeEntry> {
  const rows = await tx.$queryRaw<Array<{ id: string }>>`
    SELECT "id"
    FROM "PracticeEntry"
    WHERE "id" = ${entryId}
    FOR UPDATE
  `;
  if (rows.length === 0) {
    throw new ApiError(404, ErrorCodes.ENTRY_NOT_FOUND, 'Entry not found');
  }

  const entry = await tx.practiceEntry.findUnique({ where: { id: entryId } });
  if (!entry) {
    throw new ApiError(404, ErrorCodes.ENTRY_NOT_FOUND, 'Entry not found');
  }
  return entry;
}
