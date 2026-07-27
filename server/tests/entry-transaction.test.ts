// Uses real PostgreSQL sessions to prove advisory locks serialize conflicting entry work.
import { PrismaClient } from '@prisma/client';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { lockEntry, lockEntryIdentity, withLockedEntry } from '../src/services/entryTransaction.js';

const lockOwner = new PrismaClient();
const lockContender = new PrismaClient();

beforeAll(async () => {
  await Promise.all([lockOwner.$connect(), lockContender.$connect()]);
});

afterAll(async () => {
  await Promise.all([lockOwner.$disconnect(), lockContender.$disconnect()]);
});

describe('entry transaction locking', () => {
  it('returns a Prisma-supported scalar and holds the advisory lock until commit', async () => {
    const entryId = `entry-lock-${crypto.randomUUID()}`;

    await lockOwner.$transaction(async (tx) => {
      await expect(lockEntryIdentity(tx, entryId)).resolves.toBeUndefined();

      const [{ acquired }] = await lockContender.$queryRaw<Array<{ acquired: boolean }>>`
        SELECT pg_try_advisory_xact_lock(hashtextextended(${entryId}, 0)) AS "acquired"
      `;
      expect(acquired).toBe(false);
    });

    const [{ acquiredAfterCommit }] = await lockContender.$queryRaw<
      Array<{ acquiredAfterCommit: boolean }>
    >`
      SELECT pg_try_advisory_xact_lock(hashtextextended(${entryId}, 0)) AS "acquiredAfterCommit"
    `;
    expect(acquiredAfterCommit).toBe(true);
  });

  it('passes the row-locked entry to the transaction operation', async () => {
    const entry = { id: 'entry-locked' };
    const tx = {
      $queryRaw: async () => [{ id: entry.id }],
      practiceEntry: { findUnique: async () => entry },
    };
    const prisma = {
      $transaction: async (operation: (client: typeof tx) => Promise<string>) => operation(tx),
    };

    await expect(
      withLockedEntry(prisma as never, entry.id, async (_tx, lockedEntry) => lockedEntry.id)
    ).resolves.toBe(entry.id);
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
