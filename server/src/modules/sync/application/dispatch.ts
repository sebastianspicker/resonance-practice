/** Dispatch of typed v1 commands to their owning modules and mapping to sync results. */
import type { PracticeEntry, Prisma } from '@prisma/client';
import { ErrorCodes } from '../../../platform/http/errorCodes.js';
import { ApiError } from '../../../platform/http/errors.js';
import {
  createEntry,
  createEntryReceiptScope,
  entryReceiptScope,
  lockOwnedEntryAtVersion,
  replaceCaptureMarkers,
  submitEntry,
  updateEntry,
  type CommandReceiptScope,
} from '../../entries/application/commands.js';
import { deleteLockedEntry, lockEntryForDeletion } from '../../entries/application/deletion.js';
import { EntryVersionConflictError } from '../../entries/application/versionConflict.js';
import { queueEntryMediaRelease } from '../../media/application/storageDeletion/entryRelease.js';
import { createFeedback, feedbackReceiptScope } from '../../reviews/application/commands.js';
import { deleteFeedbackForTargets } from '../../reviews/application/feedbackDeletion.js';
import type { SyncCommand, SyncCommandResult, SyncCommandStatus } from './contract.js';

type EntryResourceInput = Pick<
  PracticeEntry,
  | 'id'
  | 'courseId'
  | 'studentId'
  | 'version'
  | 'status'
  | 'kind'
  | 'practiceDate'
  | 'goalText'
  | 'durationSeconds'
  | 'tags'
  | 'notes'
  | 'consentConfirmedAt'
  | 'consentScope'
  | 'captureProfile'
  | 'createdAt'
  | 'updatedAt'
>;

/** Receipt scope computed by the command's owning module before its handler runs. */
export async function commandReceiptScope(
  tx: Prisma.TransactionClient,
  command: SyncCommand
): Promise<CommandReceiptScope> {
  switch (command.kind) {
    case 'createEntry':
      return createEntryReceiptScope(command.entityId, command.payload);
    case 'createFeedback':
      return feedbackReceiptScope(tx, command.payload);
    default:
      return entryReceiptScope(tx, command.entityId, 'student');
  }
}

/** Apply one command; client-visible domain errors become data results. */
export async function applyOrRejectCommand(
  tx: Prisma.TransactionClient,
  userId: string,
  command: SyncCommand
): Promise<SyncCommandResult> {
  try {
    return await applyCommand(tx, userId, command);
  } catch (error) {
    if (!(error instanceof ApiError) || error.statusCode >= 500) throw error;
    return apiErrorResult(command, error);
  }
}

async function applyCommand(
  tx: Prisma.TransactionClient,
  userId: string,
  command: SyncCommand
): Promise<SyncCommandResult> {
  switch (command.kind) {
    case 'createEntry':
      return appliedEntryResult(command, await createEntry(tx, userId, command));
    case 'updateEntry':
      return appliedEntryResult(command, await updateEntry(tx, userId, command));
    case 'replaceCaptureMarkers':
      return appliedEntryResult(command, await replaceCaptureMarkers(tx, userId, command));
    case 'submitEntry':
      return appliedEntryResult(command, await submitEntry(tx, userId, command));
    case 'deleteEntry':
      return deleteEntry(tx, userId, command);
    case 'createFeedback':
      return appliedEntryResult(command, await createFeedback(tx, userId, command));
  }
}

async function deleteEntry(
  tx: Prisma.TransactionClient,
  userId: string,
  command: SyncCommand
): Promise<SyncCommandResult> {
  const entry = await lockOwnedEntryAtVersion(
    tx,
    userId,
    command.entityId,
    command.baseVersion,
    'delete'
  );
  // Identity lock, then row lock, before media and feedback for the entry are enumerated.
  await lockEntryForDeletion(tx, entry.id);
  const artifactIds = await queueEntryMediaRelease(tx, entry.id);
  await deleteFeedbackForTargets(tx, entry.id, artifactIds);
  await deleteLockedEntry(tx, entry.id);
  return baseResult(command, 'applied');
}

export function baseResult(command: SyncCommand, status: SyncCommandStatus): SyncCommandResult {
  return {
    operationId: command.operationId,
    entityId: command.entityId,
    kind: command.kind,
    status,
  };
}

function appliedEntryResult(command: SyncCommand, entry: EntryResourceInput): SyncCommandResult {
  return {
    ...baseResult(command, 'applied'),
    currentVersion: entry.version,
    resource: entryResource(entry),
  };
}

/** Optimistic-version conflicts carry the current entry; other client errors are rejections. */
export function apiErrorResult(command: SyncCommand, error: ApiError): SyncCommandResult {
  if (error instanceof EntryVersionConflictError) {
    return {
      ...baseResult(command, 'conflict'),
      code: error.code,
      message: error.message,
      currentVersion: error.entry.version,
      resource: entryResource(error.entry),
    };
  }
  return { ...baseResult(command, 'rejected'), code: error.code, message: error.message };
}

export function retryableResult(command: SyncCommand, message: string): SyncCommandResult {
  return { ...baseResult(command, 'retryable'), code: ErrorCodes.INTERNAL_ERROR, message };
}

function entryResource(entry: EntryResourceInput) {
  return {
    id: entry.id,
    courseId: entry.courseId,
    studentId: entry.studentId,
    version: entry.version,
    status: entry.status,
    kind: entry.kind,
    practiceDate: entry.practiceDate,
    goalText: entry.goalText,
    durationSeconds: entry.durationSeconds,
    tags: entry.tags,
    notes: entry.notes,
    consentConfirmedAt: entry.consentConfirmedAt,
    consentScope: entry.consentScope,
    captureProfile: entry.captureProfile,
    createdAt: entry.createdAt,
    updatedAt: entry.updatedAt,
  };
}
