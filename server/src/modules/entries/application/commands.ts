/** Transactional entry-command rules, executed by the sync gateway in client FIFO order. */
import type { CourseRole, PracticeEntry, Prisma } from '@prisma/client';
import { ErrorCodes } from '../../../platform/http/errorCodes.js';
import { ApiError } from '../../../platform/http/errors.js';
import { requireCourseMembership } from '../../courses/application/authorization.js';
import { requireStudentOwner } from './authorization.js';
import { lockEntry, lockEntryIdentity } from './locks.js';
import {
  parseCaptureMarkers,
  parseEntryCreatePayload,
  parseEntryUpdatePayload,
} from './payloads.js';
import { requireEntryVersion } from './versionConflict.js';

/** Client-generated target, optimistic version, and unparsed payload of one command. */
export type EntryCommandInput = {
  entityId: string;
  baseVersion?: number;
  payload: Record<string, unknown>;
};

/** Course role a stored command receipt requires before it may be replayed. */
export type CommandReceiptScope = {
  courseId: string;
  requiredRole: CourseRole;
  entryId?: string;
};

/** Receipt scope for createEntry, taken from the unparsed payload before the handler runs. */
export function createEntryReceiptScope(
  entityId: string,
  payload: Record<string, unknown>
): CommandReceiptScope {
  const courseId = typeof payload.courseId === 'string' ? payload.courseId : undefined;
  if (!courseId) {
    throw new ApiError(400, ErrorCodes.VALIDATION_ERROR, 'Invalid create entry receipt');
  }
  return { courseId, requiredRole: 'student' as const, entryId: entityId };
}

/** Receipt scope for commands that target an existing entry. */
export async function entryReceiptScope(
  tx: Prisma.TransactionClient,
  entryId: string,
  requiredRole: CourseRole
): Promise<CommandReceiptScope> {
  const entry = await tx.practiceEntry.findUnique({
    where: { id: entryId },
    select: { courseId: true },
  });
  if (!entry) throw new ApiError(404, ErrorCodes.ENTRY_NOT_FOUND, 'Entry not found');
  return { courseId: entry.courseId, requiredRole, entryId };
}

/** Same ID with the same content is an idempotent success that returns the existing row. */
export async function createEntry(
  tx: Prisma.TransactionClient,
  userId: string,
  { entityId, payload }: EntryCommandInput
): Promise<PracticeEntry> {
  const input = parseEntryCreatePayload(payload);
  await lockEntryIdentity(tx, entityId);
  await requireCourseMembership(
    tx,
    userId,
    input.courseId,
    'student',
    'Only course students can create entries'
  );
  const tombstone = await tx.deletedEntryTombstone.findUnique({ where: { id: entityId } });
  if (tombstone) {
    throw new ApiError(410, ErrorCodes.ENTRY_DELETED, 'Entry ID has been deleted');
  }
  const existing = await tx.practiceEntry.findUnique({ where: { id: entityId } });
  if (existing) {
    if (!matchesEntryCreate(existing, input, userId)) {
      throw new ApiError(409, ErrorCodes.ID_CONFLICT, 'Entry ID is already in use');
    }
    return existing;
  }
  return tx.practiceEntry.create({
    data: { id: entityId, studentId: userId, ...input, status: 'draft' },
  });
}

export async function updateEntry(
  tx: Prisma.TransactionClient,
  userId: string,
  { entityId, baseVersion, payload }: EntryCommandInput
): Promise<PracticeEntry> {
  const entry = await lockOwnedEntryAtVersion(tx, userId, entityId, baseVersion, 'edit entries');
  if (entry.status !== 'draft') {
    throw new ApiError(409, ErrorCodes.ENTRY_LOCKED, 'Only draft entries can be edited');
  }
  const data = parseEntryUpdatePayload(payload, entry);
  return tx.practiceEntry.update({
    where: { id: entry.id },
    data: { ...data, version: { increment: 1 } },
  });
}

export async function replaceCaptureMarkers(
  tx: Prisma.TransactionClient,
  userId: string,
  { entityId, baseVersion, payload }: EntryCommandInput
): Promise<PracticeEntry> {
  const entry = await lockOwnedEntryAtVersion(
    tx,
    userId,
    entityId,
    baseVersion,
    'sync capture markers'
  );
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
  const markers = parseCaptureMarkers(payload.markers);
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
  return tx.practiceEntry.update({
    where: { id: entry.id },
    data: { version: { increment: 1 } },
  });
}

export async function submitEntry(
  tx: Prisma.TransactionClient,
  userId: string,
  { entityId, baseVersion }: EntryCommandInput
): Promise<PracticeEntry> {
  const entry = await lockOwnedEntryAtVersion(tx, userId, entityId, baseVersion, 'submit');
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
  return tx.practiceEntry.update({
    where: { id: entry.id },
    data: { status: 'submitted', version: { increment: 1 } },
  });
}

/**
 * Lock an entry, require its student owner, then require the optimistic
 * version. A stale version throws `EntryVersionConflictError`.
 */
export async function lockOwnedEntryAtVersion(
  tx: Prisma.TransactionClient,
  userId: string,
  entryId: string,
  baseVersion: number | undefined,
  action: string
): Promise<PracticeEntry> {
  const entry = await lockEntry(tx, entryId);
  await requireStudentOwner(tx, userId, entry, action);
  requireEntryVersion(entry, baseVersion);
  return entry;
}

async function requireMarkerArtifacts(
  tx: Prisma.TransactionClient,
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
  tx: Prisma.TransactionClient,
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
