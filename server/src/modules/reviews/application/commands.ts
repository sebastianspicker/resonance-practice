/** Transactional feedback-creation rules, executed by the sync gateway in client FIFO order. */
import type { FeedbackTargetType, PracticeEntry, Prisma } from '@prisma/client';
import { ErrorCodes } from '../../../platform/http/errorCodes.js';
import { ApiError } from '../../../platform/http/errors.js';
import { requireCourseMembership } from '../../courses/application/authorization.js';
import {
  entryReceiptScope,
  type CommandReceiptScope,
  type EntryCommandInput,
} from '../../entries/application/commands.js';
import { lockEntry } from '../../entries/application/locks.js';
import { requireEntryVersion } from '../../entries/application/versionConflict.js';
import { parseFeedbackPayload } from './payloads.js';

/** Receipt scope for createFeedback, taken from the unparsed payload before the handler runs. */
export async function feedbackReceiptScope(
  tx: Prisma.TransactionClient,
  payload: Record<string, unknown>
): Promise<CommandReceiptScope> {
  const targetId = typeof payload.targetId === 'string' ? payload.targetId : undefined;
  if ((payload.targetType === 'entry' || payload.targetType === 'artifact') && targetId) {
    const entryId = await resolveFeedbackEntryId(tx, payload.targetType, targetId);
    return entryReceiptScope(tx, entryId, 'teacher');
  }
  throw new ApiError(400, ErrorCodes.VALIDATION_ERROR, 'Invalid feedback receipt');
}

/**
 * Create feedback and mark the entry reviewed. Returns the updated entry, or
 * the current entry when identical feedback with this ID already exists.
 */
export async function createFeedback(
  tx: Prisma.TransactionClient,
  userId: string,
  { entityId, baseVersion, payload }: EntryCommandInput
): Promise<PracticeEntry> {
  const input = parseFeedbackPayload(payload);
  const entryId = await resolveFeedbackEntryId(tx, input.targetType, input.targetId);
  const entry = await lockEntry(tx, entryId);
  await requireFeedbackTarget(tx, entry, input.targetType, input.targetId);
  await requireCourseMembership(
    tx,
    userId,
    entry.courseId,
    'teacher',
    'Only course teachers can create feedback'
  );
  requireEntryVersion(entry, baseVersion);
  requireSubmittedEntry(entry);
  const existing = await tx.feedback.findUnique({
    where: { id: entityId },
    include: { markers: true },
  });
  if (existing) {
    if (!matchesFeedback(existing, input, userId, entry.id)) {
      throw new ApiError(409, ErrorCodes.ID_CONFLICT, 'Feedback ID already exists');
    }
    return entry;
  }
  await tx.feedback.create({
    data: {
      id: entityId,
      targetType: input.targetType,
      targetId: input.targetId,
      teacherId: userId,
      entryId: entry.id,
      status: input.status,
      commentsText: input.commentsText,
      markers: { create: input.markers },
    },
  });
  return tx.practiceEntry.update({
    where: { id: entry.id },
    data: { status: 'reviewed', version: { increment: 1 } },
  });
}

function requireSubmittedEntry(entry: PracticeEntry): void {
  if (entry.status === 'draft') {
    throw new ApiError(
      409,
      ErrorCodes.ENTRY_NOT_SUBMITTED,
      'Entry must be submitted before feedback can be added'
    );
  }
}

async function resolveFeedbackEntryId(
  tx: Prisma.TransactionClient,
  targetType: FeedbackTargetType,
  targetId: string
): Promise<string> {
  if (targetType === 'entry') return targetId;
  const artifact = await tx.artifact.findUnique({
    where: { id: targetId },
    select: { entryId: true },
  });
  if (!artifact) throw new ApiError(404, ErrorCodes.ARTIFACT_NOT_FOUND, 'Artifact not found');
  return artifact.entryId;
}

async function requireFeedbackTarget(
  tx: Prisma.TransactionClient,
  entry: PracticeEntry,
  targetType: FeedbackTargetType,
  targetId: string
): Promise<void> {
  if (targetType === 'entry') {
    if (targetId !== entry.id) {
      throw new ApiError(404, ErrorCodes.ENTRY_NOT_FOUND, 'Entry not found');
    }
    return;
  }
  const artifact = await tx.artifact.findUnique({ where: { id: targetId } });
  if (!artifact || artifact.entryId !== entry.id) {
    throw new ApiError(404, ErrorCodes.ARTIFACT_NOT_FOUND, 'Artifact not found');
  }
}

function matchesFeedback(
  existing: {
    teacherId: string;
    targetType: FeedbackTargetType;
    targetId: string;
    entryId: string | null;
    status: string;
    commentsText: string;
    markers: Array<{ id: string; timeSeconds: number; text: string }>;
  },
  input: ReturnType<typeof parseFeedbackPayload>,
  userId: string,
  entryId: string
): boolean {
  const sameFields = [
    existing.teacherId === userId,
    existing.targetType === input.targetType,
    existing.targetId === input.targetId,
    existing.entryId === entryId,
    existing.status === input.status,
    existing.commentsText === input.commentsText,
  ].every(Boolean);
  if (!sameFields || existing.markers.length !== input.markers.length) return false;

  const current = [...existing.markers].sort((left, right) => left.id.localeCompare(right.id));
  const requested = [...input.markers].sort((left, right) => left.id.localeCompare(right.id));
  return current.every(
    (marker, index) =>
      marker.id === requested.at(index)?.id &&
      marker.timeSeconds === requested.at(index)?.timeSeconds &&
      marker.text === requested.at(index)?.text
  );
}
