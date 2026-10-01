/** Entry-owned steps of a transactional deletion; callers compose child cleanup between them. */
import type { Prisma } from '@prisma/client';
import { assertEntryActive, lockEntry, lockEntryIdentity } from './locks.js';

/**
 * Lock an entry for deletion. The advisory ID lock prevents a concurrent
 * create from reusing this ID after the row is deleted but before its
 * tombstone is committed.
 */
export async function lockEntryForDeletion(
  tx: Prisma.TransactionClient,
  entryId: string
): Promise<void> {
  await lockEntryIdentity(tx, entryId);
  assertEntryActive(await lockEntry(tx, entryId));
}

/** Remove a locked entry and its artifact rows, leaving a tombstone for its ID. */
export async function deleteLockedEntry(
  tx: Prisma.TransactionClient,
  entryId: string
): Promise<void> {
  await tx.artifact.deleteMany({ where: { entryId } });
  await tx.deletedEntryTombstone.upsert({
    where: { id: entryId },
    create: { id: entryId },
    update: {},
  });
  await tx.practiceEntry.delete({ where: { id: entryId } });
}
