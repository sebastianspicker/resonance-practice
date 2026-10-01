/** Durable storage-deletion scheduling that never outruns issued credentials or claims. */
import type { Prisma } from '@prisma/client';
import { artifactCompletionClaimLeaseEnd } from '../completionLease.js';

const ARTIFACT_CLEANUP_GRACE_MS = 5 * 60_000;

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
  tx: Prisma.TransactionClient,
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
