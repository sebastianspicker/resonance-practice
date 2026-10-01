/** Entry identity and row locks that serialize practice-entry state transitions. */
import type { PracticeEntry, Prisma } from '@prisma/client';
import {
  advisoryTransactionLock,
  AdvisoryLockNamespace,
} from '../../../platform/database/advisoryLocks.js';
import { ErrorCodes } from '../../../platform/http/errorCodes.js';
import { ApiError } from '../../../platform/http/errors.js';

export function assertEntryActive(entry: { deletedAt: Date | null }) {
  if (entry.deletedAt) {
    throw new ApiError(410, ErrorCodes.ENTRY_DELETED, 'Entry has been deleted');
  }
}

/** Serialize creation and deletion for one client-generated entry ID. */
export async function lockEntryIdentity(
  tx: Prisma.TransactionClient,
  entryId: string
): Promise<void> {
  await advisoryTransactionLock(tx, entryId, AdvisoryLockNamespace.entryIdentity);
}

/**
 * Serialize state transitions for one practice entry.
 *
 * Child creation, submission, feedback, marker updates, and deletion all use
 * this same parent-row lock so their state checks cannot be invalidated by a
 * concurrent request before the matching write commits.
 */
export async function lockEntry(
  tx: Prisma.TransactionClient,
  entryId: string
): Promise<PracticeEntry> {
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
