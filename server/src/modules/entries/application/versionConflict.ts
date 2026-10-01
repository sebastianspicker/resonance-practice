/** Optimistic entry versions: conflict checks and the single owner of version bumps. */
import type { PracticeEntry, Prisma } from '@prisma/client';
import { ErrorCodes } from '../../../platform/http/errorCodes.js';
import { ApiError } from '../../../platform/http/errors.js';

export class EntryVersionConflictError extends ApiError {
  readonly entry: PracticeEntry;

  constructor(entry: PracticeEntry) {
    super(409, ErrorCodes.VERSION_CONFLICT, 'Entry has changed on the server', {
      actual: entry.version,
    });
    this.entry = entry;
  }
}

/** Reject the transition unless it targets the entry's current optimistic version. */
export function requireEntryVersion(entry: PracticeEntry, baseVersion: number | undefined): void {
  if (entry.version !== baseVersion) throw new EntryVersionConflictError(entry);
}

/** Advance the entry's optimistic version, applying any accompanying field changes in one update. */
export function bumpEntryVersion(
  tx: Prisma.TransactionClient,
  entryId: string,
  data: Omit<Prisma.PracticeEntryUncheckedUpdateInput, 'version'> = {}
): Promise<PracticeEntry> {
  return tx.practiceEntry.update({
    where: { id: entryId },
    data: { ...data, version: { increment: 1 } },
  });
}
