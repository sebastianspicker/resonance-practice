/** Transaction-scoped PostgreSQL advisory locks with stable per-namespace identity keys. */
import type { Prisma } from '@prisma/client';

/**
 * Seeds passed to `hashtextextended`; changing a value changes persisted lock keys.
 *
 * `userQuota` is intentionally shared by sync receipt admission and artifact
 * quota admission, so both per-user quota checks serialize against each other.
 */
export const AdvisoryLockNamespace = {
  entryIdentity: 0,
  operationIdentity: 1,
  artifactSession: 2,
  userQuota: 3,
} as const;

type AdvisoryLockNamespaceSeed = (typeof AdvisoryLockNamespace)[keyof typeof AdvisoryLockNamespace];

/** Block until this transaction holds the advisory lock for one identity in a namespace. */
export async function advisoryTransactionLock(
  tx: Prisma.TransactionClient,
  identity: string,
  namespace: AdvisoryLockNamespaceSeed
): Promise<void> {
  await tx.$queryRaw<Array<{ locked: string }>>`
    SELECT pg_advisory_xact_lock(hashtextextended(${identity}, ${namespace}))::text AS "locked"
  `;
}

/** Serialize one user's idempotency key before reading or writing its receipt. */
export async function lockOperationIdentity(
  tx: Prisma.TransactionClient,
  userId: string,
  operationId: string
): Promise<void> {
  await advisoryTransactionLock(
    tx,
    `${userId}:${operationId}`,
    AdvisoryLockNamespace.operationIdentity
  );
}
