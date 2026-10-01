// Uses real PostgreSQL sessions to prove advisory locks serialize conflicting entry work.
import { type Prisma, PrismaClient } from '@prisma/client';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { lockOperationIdentity } from '../src/platform/database/advisoryLocks.js';
import { lockEntry, lockEntryIdentity } from '../src/modules/entries/application/locks.js';
import { lockArtifactSessionIdentity } from '../src/modules/media/application/completionClaims.js';
import { lockArtifactQuotaIdentity } from '../src/modules/media/application/uploadQuota.js';
import { admitSyncReceipt } from '../src/modules/sync/application/receipts.js';

const lockOwner = new PrismaClient();
const lockContender = new PrismaClient();

beforeAll(async () => {
  await Promise.all([lockOwner.$connect(), lockContender.$connect()]);
});

afterAll(async () => {
  await Promise.all([lockOwner.$disconnect(), lockContender.$disconnect()]);
});

async function contenderAcquires(identity: string, seed: number): Promise<boolean> {
  const rows = await lockContender.$queryRaw<Array<{ acquired: boolean }>>`
    SELECT pg_try_advisory_xact_lock(hashtextextended(${identity}, ${seed})) AS "acquired"
  `;
  return rows[0]?.acquired === true;
}

/** Assert that `lock` holds exactly the (identity, seed) advisory key until commit. */
async function expectLockHeldUntilCommit(
  lock: (tx: Prisma.TransactionClient) => Promise<void>,
  identity: string,
  seed: number
) {
  await lockOwner.$transaction(async (tx) => {
    await expect(lock(tx)).resolves.toBeUndefined();
    expect(await contenderAcquires(identity, seed)).toBe(false);
  });
  expect(await contenderAcquires(identity, seed)).toBe(true);
}

describe('advisory transaction locking', () => {
  it('returns a Prisma-supported scalar and holds the advisory lock until commit', async () => {
    const entryId = `entry-lock-${crypto.randomUUID()}`;
    await expectLockHeldUntilCommit((tx) => lockEntryIdentity(tx, entryId), entryId, 0);
  });

  it('holds the seed-1 operation identity lock until commit', async () => {
    const userId = `user-lock-${crypto.randomUUID()}`;
    const operationId = `operation-lock-${crypto.randomUUID()}`;
    await expectLockHeldUntilCommit(
      (tx) => lockOperationIdentity(tx, userId, operationId),
      `${userId}:${operationId}`,
      1
    );
  });

  it('holds the seed-2 artifact session identity lock until commit', async () => {
    const sessionId = `session-lock-${crypto.randomUUID()}`;
    await expectLockHeldUntilCommit(
      (tx) => lockArtifactSessionIdentity(tx, sessionId),
      sessionId,
      2
    );
  });

  it('holds the seed-3 user quota lock for artifact and sync receipt admission', async () => {
    const userId = `user-quota-${crypto.randomUUID()}`;
    await expectLockHeldUntilCommit((tx) => lockArtifactQuotaIdentity(tx, userId), userId, 3);
    await expectLockHeldUntilCommit((tx) => admitSyncReceipt(tx, userId), userId, 3);
  });

  it('serializes sync receipt admission behind artifact quota admission for one user', async () => {
    const userId = `user-quota-${crypto.randomUUID()}`;
    await lockOwner.$transaction(async (tx) => {
      await lockArtifactQuotaIdentity(tx, userId);
      await expect(
        lockContender.$transaction(async (contender) => {
          await contender.$executeRaw`SET LOCAL lock_timeout = '200ms'`;
          await admitSyncReceipt(contender, userId);
        })
      ).rejects.toThrow(/lock timeout/);
    });
  });

  it('returns the row-locked entry', async () => {
    const entry = { id: 'entry-locked' };
    const tx = {
      $queryRaw: async () => [{ id: entry.id }],
      practiceEntry: { findUnique: async () => entry },
    };

    await expect(lockEntry(tx as never, entry.id)).resolves.toBe(entry);
  });

  it.each([
    {
      name: 'the row lock finds no entry',
      tx: { $queryRaw: async () => [], practiceEntry: { findUnique: async () => null } },
    },
    {
      name: 'the entry disappears after the row lock',
      tx: {
        $queryRaw: async () => [{ id: 'entry-missing' }],
        practiceEntry: { findUnique: async () => null },
      },
    },
  ])('returns ENTRY_NOT_FOUND when $name', async ({ tx }) => {
    await expect(lockEntry(tx as never, 'entry-missing')).rejects.toMatchObject({
      statusCode: 404,
      code: 'ENTRY_NOT_FOUND',
    });
  });
});
