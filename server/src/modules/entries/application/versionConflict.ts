/** Optimistic-version conflicts for entry state transitions, carrying the current entry. */
import type { PracticeEntry } from '@prisma/client';
import { ErrorCodes } from '../../../platform/http/errorCodes.js';
import { ApiError } from '../../../platform/http/errors.js';

export class EntryVersionConflictError extends ApiError {
  readonly entry: PracticeEntry;

  constructor(entry: PracticeEntry) {
    super(409, ErrorCodes.VERSION_CONFLICT, 'Entry has changed on the server');
    this.entry = entry;
  }
}

/** Reject the transition unless it targets the entry's current optimistic version. */
export function requireEntryVersion(entry: PracticeEntry, baseVersion: number | undefined): void {
  if (entry.version !== baseVersion) throw new EntryVersionConflictError(entry);
}
