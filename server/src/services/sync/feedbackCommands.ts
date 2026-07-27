/** Transactional v1 feedback-command handler for the sync command pipeline. */
import type { FeedbackTargetType, PracticeEntry } from '@prisma/client';
import { ErrorCodes } from '../../errorCodes.js';
import { ApiError } from '../../errors.js';
import { type EntryTransaction, lockEntry } from '../entryTransaction.js';
import type { SyncCommand, SyncCommandResult } from './contract.js';
import { appliedEntryResult, requireVersion } from './entryCommands.js';
import { parseFeedbackPayload } from './payloads.js';

export async function createFeedback(
  tx: EntryTransaction,
  userId: string,
  command: SyncCommand
): Promise<SyncCommandResult> {
  const input = parseFeedbackPayload(command.payload);
  const entryId = await resolveFeedbackEntryId(tx, input.targetType, input.targetId);
  const entry = await lockEntry(tx, entryId);
  await requireFeedbackTarget(tx, entry, input.targetType, input.targetId);
  await requireFeedbackTeacher(tx, userId, entry.courseId);
  const versionResult = requireVersion(command, entry);
  if (versionResult) return versionResult;
  requireSubmittedEntry(entry);
  const existing = await tx.feedback.findUnique({
    where: { id: command.entityId },
    include: { markers: true },
  });
  if (existing) {
    if (!matchesFeedback(existing, input, userId, entry.id)) {
      throw new ApiError(409, ErrorCodes.ID_CONFLICT, 'Feedback ID already exists');
    }
    return appliedEntryResult(command, entry);
  }
  await tx.feedback.create({
    data: {
      id: command.entityId,
      targetType: input.targetType,
      targetId: input.targetId,
      teacherId: userId,
      entryId: entry.id,
      status: input.status,
      commentsText: input.commentsText,
      markers: { create: input.markers },
    },
  });
  const updated = await tx.practiceEntry.update({
    where: { id: entry.id },
    data: { status: 'reviewed', version: { increment: 1 } },
  });
  return appliedEntryResult(command, updated);
}

async function requireFeedbackTeacher(
  tx: EntryTransaction,
  userId: string,
  courseId: string
): Promise<void> {
  const membership = await tx.membership.findUnique({
    where: { userId_courseId: { userId, courseId } },
  });
  if (!membership || membership.roleInCourse !== 'teacher') {
    throw new ApiError(403, ErrorCodes.TEACHER_ONLY, 'Only course teachers can create feedback');
  }
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
  tx: EntryTransaction,
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
  tx: EntryTransaction,
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
