import type { PracticeEntry } from '@prisma/client';
import { ErrorCodes } from '../../errorCodes.js';
import { ApiError } from '../../errors.js';
import type { EntryTransaction } from '../../services/entryTransaction.js';
import { feedbackBodyMatches, type FeedbackMarker, type ParsedFeedbackRequest } from './parsing.js';
import { requireActiveLockedEntry, requireLockedFeedbackTarget } from './target.js';

export type FeedbackInput = {
  userId: string;
  requestedFeedbackId: string | undefined;
  feedbackId: string;
  targetType: ParsedFeedbackRequest['targetType'];
  targetId: string;
  reviewEntryId: string;
  status: ParsedFeedbackRequest['status'];
  commentsText: string;
  markers: FeedbackMarker[];
  markerCreates: Array<{ id: string; timeSeconds: number; text: string }>;
};

export async function processLockedFeedback(
  tx: EntryTransaction,
  lockedEntry: PracticeEntry,
  input: FeedbackInput
) {
  requireActiveLockedEntry(lockedEntry);
  await requireLockedFeedbackTarget(tx, lockedEntry, input.targetType, input.targetId);

  const existingFeedback = await findExistingFeedback(tx, input.requestedFeedbackId);
  if (existingFeedback) {
    requireMatchingFeedback(existingFeedback, input);
    if (lockedEntry.status !== 'reviewed') {
      await markEntryReviewed(tx, input.reviewEntryId);
    }
    return { feedback: existingFeedback, created: false };
  }

  const feedback = await tx.feedback.create({
    data: {
      id: input.feedbackId,
      targetType: input.targetType,
      targetId: input.targetId,
      teacherId: input.userId,
      entryId: input.reviewEntryId,
      status: input.status,
      commentsText: input.commentsText,
      markers: { create: input.markerCreates },
    },
    include: { markers: true, teacher: true },
  });

  // Product rule: any teacher feedback, whether on the entry or one of its
  // artifacts, marks the parent entry as reviewed.
  await markEntryReviewed(tx, input.reviewEntryId);
  return { feedback, created: true };
}

function findExistingFeedback(tx: EntryTransaction, requestedFeedbackId: string | undefined) {
  return requestedFeedbackId
    ? tx.feedback.findUnique({
        where: { id: requestedFeedbackId },
        include: { markers: true, teacher: true },
      })
    : null;
}

function requireMatchingFeedback(
  existingFeedback: {
    teacherId: string;
    targetType: string;
    targetId: string;
    entryId: string | null;
    status: string;
    commentsText: string;
    markers: FeedbackMarker[];
  },
  input: FeedbackInput
): void {
  if (
    existingFeedback.teacherId !== input.userId ||
    existingFeedback.targetType !== input.targetType ||
    existingFeedback.targetId !== input.targetId ||
    existingFeedback.entryId !== input.reviewEntryId ||
    !feedbackBodyMatches(existingFeedback, input)
  ) {
    throw new ApiError(409, ErrorCodes.ID_CONFLICT, 'Feedback ID already exists');
  }
}

async function markEntryReviewed(tx: EntryTransaction, reviewEntryId: string): Promise<void> {
  await tx.practiceEntry.update({
    where: { id: reviewEntryId },
    data: { status: 'reviewed', version: { increment: 1 } },
  });
}
