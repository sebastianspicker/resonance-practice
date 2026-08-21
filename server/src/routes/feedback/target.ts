import type { PracticeEntry, PrismaClient } from '@prisma/client';
import { ErrorCodes } from '../../errorCodes.js';
import { ApiError } from '../../errors.js';
import type { EntryTransaction } from '../../services/entryTransaction.js';
import type { ParsedFeedbackRequest } from './parsing.js';

export async function resolveFeedbackTarget(
  prisma: PrismaClient,
  targetType: ParsedFeedbackRequest['targetType'],
  targetId: string
): Promise<{ courseId: string; reviewEntryId: string }> {
  if (targetType === 'entry') {
    const entry = await prisma.practiceEntry.findUnique({ where: { id: targetId } });
    if (!entry) throw new ApiError(404, ErrorCodes.ENTRY_NOT_FOUND, 'Entry not found');
    requireSubmittedEntry(entry);
    return { courseId: entry.courseId, reviewEntryId: entry.id };
  }

  const artifact = await prisma.artifact.findUnique({
    where: { id: targetId },
    include: { entry: true },
  });
  if (!artifact) throw new ApiError(404, ErrorCodes.ARTIFACT_NOT_FOUND, 'Artifact not found');
  requireSubmittedEntry(artifact.entry);
  return { courseId: artifact.entry.courseId, reviewEntryId: artifact.entry.id };
}

export function requireActiveLockedEntry(lockedEntry: PracticeEntry): void {
  requireSubmittedEntry(lockedEntry);
}

export async function requireLockedFeedbackTarget(
  tx: EntryTransaction,
  lockedEntry: PracticeEntry,
  targetType: ParsedFeedbackRequest['targetType'],
  targetId: string
): Promise<void> {
  // The target may have changed while authorization was evaluated. Re-resolve
  // it under the same parent-entry lock used by related entry mutations.
  if (targetType === 'entry') {
    if (targetId !== lockedEntry.id) {
      throw new ApiError(404, ErrorCodes.ENTRY_NOT_FOUND, 'Entry not found');
    }
    return;
  }

  const lockedArtifact = await tx.artifact.findUnique({ where: { id: targetId } });
  if (!lockedArtifact || lockedArtifact.entryId !== lockedEntry.id) {
    throw new ApiError(404, ErrorCodes.ARTIFACT_NOT_FOUND, 'Artifact not found');
  }
}

function requireSubmittedEntry(entry: Pick<PracticeEntry, 'deletedAt' | 'status'>): void {
  if (entry.deletedAt) {
    throw new ApiError(410, ErrorCodes.ENTRY_DELETED, 'Entry has been deleted');
  }
  if (entry.status === 'draft') {
    throw new ApiError(
      409,
      ErrorCodes.ENTRY_NOT_SUBMITTED,
      'Entry must be submitted before feedback can be added'
    );
  }
}
