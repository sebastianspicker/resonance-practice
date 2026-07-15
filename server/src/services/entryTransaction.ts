import type { PracticeEntry, Prisma, PrismaClient } from '@prisma/client';
import { ErrorCodes } from '../errorCodes.js';
import { ApiError } from '../errors.js';

export type EntryTransaction = Prisma.TransactionClient;

/** Serialize creation and deletion for one client-generated entry ID. */
export async function lockEntryIdentity(tx: EntryTransaction, entryId: string): Promise<void> {
  await tx.$queryRaw<Array<{ locked: string }>>`
    SELECT pg_advisory_xact_lock(hashtextextended(${entryId}, 0))::text AS "locked"
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
