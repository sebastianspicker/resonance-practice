/** Transactional v1 entry-command handlers, executed in client FIFO order. */
import type { PracticeEntry } from '@prisma/client';
import { ErrorCodes } from '../../errorCodes.js';
import { ApiError } from '../../errors.js';
import { cascadeDeleteEntryInTransaction } from '../entryCascade.js';
import { type EntryTransaction, lockEntry, lockEntryIdentity } from '../entryTransaction.js';
import type { SyncCommand, SyncCommandResult, SyncCommandStatus } from './contract.js';
import {
  parseCaptureMarkers,
  parseEntryCreatePayload,
  parseEntryUpdatePayload,
} from './payloads.js';

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

export async function createEntry(
  tx: EntryTransaction,
  userId: string,
  command: SyncCommand
): Promise<SyncCommandResult> {
  const input = parseEntryCreatePayload(command.payload);
  await lockEntryIdentity(tx, command.entityId);
  const membership = await tx.membership.findUnique({
    where: { userId_courseId: { userId, courseId: input.courseId } },
  });
  if (!membership || membership.roleInCourse !== 'student') {
    throw new ApiError(403, ErrorCodes.STUDENT_ONLY, 'Only course students can create entries');
  }
  const tombstone = await tx.deletedEntryTombstone.findUnique({ where: { id: command.entityId } });
  if (tombstone) {
    throw new ApiError(410, ErrorCodes.ENTRY_DELETED, 'Entry ID has been deleted');
  }
  const existing = await tx.practiceEntry.findUnique({ where: { id: command.entityId } });
  if (existing) {
    if (!matchesEntryCreate(existing, input, userId)) {
      throw new ApiError(409, ErrorCodes.ID_CONFLICT, 'Entry ID is already in use');
    }
    return appliedEntryResult(command, existing);
  }
  const created = await tx.practiceEntry.create({
    data: { id: command.entityId, studentId: userId, ...input, status: 'draft' },
  });
  return appliedEntryResult(command, created);
}

export async function updateEntry(
  tx: EntryTransaction,
  userId: string,
  command: SyncCommand
): Promise<SyncCommandResult> {
  const entry = await lockStudentEntry(tx, userId, command.entityId, 'edit entries');
  const versionResult = requireVersion(command, entry);
  if (versionResult) return versionResult;
  if (entry.status !== 'draft') {
    throw new ApiError(409, ErrorCodes.ENTRY_LOCKED, 'Only draft entries can be edited');
  }
  const data = parseEntryUpdatePayload(command.payload, entry);
  const updated = await tx.practiceEntry.update({
    where: { id: entry.id },
    data: { ...data, version: { increment: 1 } },
  });
  return appliedEntryResult(command, updated);
}

export async function replaceCaptureMarkers(
  tx: EntryTransaction,
  userId: string,
  command: SyncCommand
): Promise<SyncCommandResult> {
  const entry = await lockStudentEntry(tx, userId, command.entityId, 'sync capture markers');
  const versionResult = requireVersion(command, entry);
  if (versionResult) return versionResult;
  if (entry.kind !== 'teaching_lesson') {
    throw new ApiError(
      400,
      ErrorCodes.VALIDATION_ERROR,
      'Capture markers are only valid for teaching lesson entries'
    );
  }
  if (entry.status === 'reviewed') {
    throw new ApiError(409, ErrorCodes.ENTRY_LOCKED, 'Reviewed entries cannot be edited');
  }
  const markers = parseCaptureMarkers(command.payload.markers);
  await requireMarkerArtifacts(
    tx,
    entry.id,
    markers.map((marker) => marker.artifactId)
  );
  await requireMarkerIdentities(
    tx,
    entry.id,
    userId,
    markers.map((marker) => marker.id)
  );
  for (const marker of markers) {
    await tx.captureMarker.upsert({
      where: { id: marker.id },
      create: { ...marker, entryId: entry.id, studentId: userId },
      update: {
        artifactId: marker.artifactId,
        timeSeconds: marker.timeSeconds,
        kind: marker.kind,
        note: marker.note,
      },
    });
  }
  await tx.captureMarker.deleteMany({
    where: {
      entryId: entry.id,
      studentId: userId,
      ...(markers.length > 0 ? { id: { notIn: markers.map((marker) => marker.id) } } : {}),
    },
  });
  const updated = await tx.practiceEntry.update({
    where: { id: entry.id },
    data: { version: { increment: 1 } },
  });
  return appliedEntryResult(command, updated);
}

export async function submitEntry(
  tx: EntryTransaction,
  userId: string,
  command: SyncCommand
): Promise<SyncCommandResult> {
  const entry = await lockStudentEntry(tx, userId, command.entityId, 'submit');
  const versionResult = requireVersion(command, entry);
  if (versionResult) return versionResult;
  if (entry.status !== 'draft') {
    throw new ApiError(409, ErrorCodes.ENTRY_LOCKED, 'Only draft entries can be submitted');
  }
  if (
    entry.kind === 'teaching_lesson' &&
    (entry.consentConfirmedAt === null || entry.consentScope === null)
  ) {
    throw new ApiError(
      409,
      ErrorCodes.CONSENT_REQUIRED,
      'Teaching lesson entries require confirmed consent before submission'
    );
  }
  const artifacts = await tx.artifact.findMany({ where: { entryId: entry.id } });
  if (artifacts.length === 0 || artifacts.some((artifact) => artifact.uploadState !== 'uploaded')) {
    throw new ApiError(
      409,
      ErrorCodes.ARTIFACTS_NOT_UPLOADED,
      'Upload artifacts before submitting'
    );
  }
  if (
    entry.kind === 'teaching_lesson' &&
    !artifacts.some((artifact) => artifact.type === 'video')
  ) {
    throw new ApiError(
      409,
      ErrorCodes.ARTIFACTS_NOT_UPLOADED,
      'Teaching lesson entries require an uploaded video artifact'
    );
  }
  const updated = await tx.practiceEntry.update({
    where: { id: entry.id },
    data: { status: 'submitted', version: { increment: 1 } },
  });
  return appliedEntryResult(command, updated);
}

export async function deleteEntry(
  tx: EntryTransaction,
  userId: string,
  command: SyncCommand
): Promise<SyncCommandResult> {
  const entry = await lockStudentEntry(tx, userId, command.entityId, 'delete');
  const versionResult = requireVersion(command, entry);
  if (versionResult) return versionResult;
  await cascadeDeleteEntryInTransaction(tx, entry.id);
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

export function appliedEntryResult(
  command: SyncCommand,
  entry: EntryResourceInput
): SyncCommandResult {
  return {
    ...baseResult(command, 'applied'),
    currentVersion: entry.version,
    resource: entryResource(entry),
  };
}

/** Return a conflict result unless the command targets the current optimistic version. */
export function requireVersion(
  command: SyncCommand,
  entry: PracticeEntry
): SyncCommandResult | null {
  if (entry.version === command.baseVersion) return null;
  return {
    ...baseResult(command, 'conflict'),
    code: ErrorCodes.VERSION_CONFLICT,
    message: 'Entry has changed on the server',
    currentVersion: entry.version,
    resource: entryResource(entry),
  };
}

async function lockStudentEntry(
  tx: EntryTransaction,
  userId: string,
  entryId: string,
  action: string
): Promise<PracticeEntry> {
  const entry = await lockEntry(tx, entryId);
  const membership = await tx.membership.findUnique({
    where: { userId_courseId: { userId, courseId: entry.courseId } },
  });
  if (!membership || membership.roleInCourse !== 'student' || entry.studentId !== userId) {
    throw new ApiError(403, ErrorCodes.STUDENT_ONLY, `Only the student owner can ${action}`);
  }
  return entry;
}

async function requireMarkerArtifacts(
  tx: EntryTransaction,
  entryId: string,
  rawArtifactIds: string[]
): Promise<void> {
  const artifactIds = [...new Set(rawArtifactIds)];
  if (artifactIds.length === 0) return;
  const artifacts = await tx.artifact.findMany({
    where: { id: { in: artifactIds }, entryId },
    select: { id: true, type: true },
  });
  const validIds = new Set(
    artifacts.filter((artifact) => artifact.type === 'video').map((artifact) => artifact.id)
  );
  if (artifactIds.some((artifactId) => !validIds.has(artifactId))) {
    throw new ApiError(
      404,
      ErrorCodes.ARTIFACT_NOT_FOUND,
      'Capture marker artifact not found for this entry'
    );
  }
}

async function requireMarkerIdentities(
  tx: EntryTransaction,
  entryId: string,
  userId: string,
  markerIds: string[]
): Promise<void> {
  if (markerIds.length === 0) return;
  const existing = await tx.captureMarker.findMany({
    where: { id: { in: markerIds } },
    select: { entryId: true, studentId: true },
  });
  if (existing.some((marker) => marker.entryId !== entryId || marker.studentId !== userId)) {
    throw new ApiError(409, ErrorCodes.ID_CONFLICT, 'A capture marker ID belongs to another entry');
  }
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

function matchesEntryCreate(
  entry: PracticeEntry,
  input: ReturnType<typeof parseEntryCreatePayload>,
  userId: string
): boolean {
  return (
    entry.studentId === userId &&
    entry.courseId === input.courseId &&
    entry.kind === input.kind &&
    entry.practiceDate.getTime() === input.practiceDate.getTime() &&
    entry.goalText === input.goalText &&
    entry.durationSeconds === input.durationSeconds &&
    entry.tags.length === input.tags.length &&
    entry.tags.every((tag, index) => tag === input.tags[index]) &&
    entry.notes === input.notes &&
    entry.consentConfirmedAt?.getTime() === input.consentConfirmedAt?.getTime() &&
    entry.consentScope === input.consentScope &&
    entry.captureProfile === input.captureProfile
  );
}
