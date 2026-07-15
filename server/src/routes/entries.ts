import type { PracticeEntry, PrismaClient } from '@prisma/client';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { limits } from '../config.js';
import { ErrorCodes } from '../errorCodes.js';
import { ApiError, isPrismaError, withPrismaErrors } from '../errors.js';
import { cascadeDeleteEntry } from '../services/entryCascade.js';
import { lockEntryIdentity, withLockedEntry } from '../services/entryTransaction.js';
import {
  requireBoolean,
  requireClientId,
  requireCourseRole,
  requireEntryAccess,
  requireEnum,
  requireField,
  requireNumber,
  requireRecord,
  requireString,
  requireStringArray,
  requireStudentOwner,
  requireValidDate,
} from '../validation.js';

const CAPTURE_PROFILES = [
  'room_overview',
  'teacher_learner',
  'instrument_closeup',
  'ensemble_group',
  'group_work',
] as const;

const CAPTURE_MARKER_KINDS = [
  'phase_setup',
  'phase_modeling',
  'phase_guided_practice',
  'phase_student_work',
  'phase_feedback',
  'phase_reflection',
  'moment_question',
  'moment_musical_model',
  'moment_student_response',
  'moment_transition',
  'privacy_note',
] as const;

const RESTRICTED_ENTRY_PATCH_FIELDS = [
  'goalText',
  'practiceDate',
  'tags',
  'durationSeconds',
  'notes',
  'kind',
  'consentConfirmed',
  'consentScope',
  'captureProfile',
];

type EntryKind = 'practice' | 'teaching_lesson';
type ConsentScope = 'private_course_review';
type CaptureProfile = (typeof CAPTURE_PROFILES)[number];

type EntryMetadata = {
  kind: EntryKind;
  consentConfirmedAt: Date | null;
  consentScope: ConsentScope | null;
  captureProfile: CaptureProfile | null;
};

type EntryPatchBase = Pick<
  PracticeEntry,
  'kind' | 'consentConfirmedAt' | 'consentScope' | 'captureProfile'
>;

function normalizeTags(rawTags: unknown) {
  const tags = requireStringArray(rawTags, 'tags', { max: limits.maxTags });
  const normalized: string[] = [];
  for (let index = 0; index < limits.maxTags; index += 1) {
    if (index >= tags.length) break;
    normalized.push(
      requireString(tags[index], 'tags[]', { minLength: 1, max: limits.maxTagLength })
    );
  }
  return normalized;
}

function optionalDurationSeconds(body: Record<string, unknown>) {
  if (body.durationSeconds === undefined) {
    return null;
  }
  return requireNumber(body.durationSeconds, 'durationSeconds', {
    integer: true,
    min: 0,
    max: limits.maxDurationSeconds,
  });
}

function nullablePatchDurationSeconds(value: unknown) {
  if (value === null) {
    return null;
  }
  return requireNumber(value, 'durationSeconds', {
    integer: true,
    min: 0,
    max: limits.maxDurationSeconds,
  });
}

function validateEntryMetadata(metadata: EntryMetadata) {
  if (
    metadata.kind === 'practice' &&
    (metadata.consentConfirmedAt !== null || metadata.consentScope !== null)
  ) {
    throw new ApiError(
      400,
      ErrorCodes.VALIDATION_ERROR,
      'Consent metadata is only valid for teaching lesson entries'
    );
  }
  if (metadata.consentConfirmedAt === null && metadata.consentScope !== null) {
    throw new ApiError(
      400,
      ErrorCodes.VALIDATION_ERROR,
      'consentScope is only valid when consentConfirmed is true'
    );
  }
  if (metadata.consentConfirmedAt !== null && metadata.consentScope === null) {
    throw new ApiError(
      400,
      ErrorCodes.VALIDATION_ERROR,
      'consentScope is required when consentConfirmed is true'
    );
  }
  if (metadata.kind === 'practice' && metadata.captureProfile !== null) {
    throw new ApiError(
      400,
      ErrorCodes.VALIDATION_ERROR,
      'captureProfile is only valid for teaching lesson entries'
    );
  }
}

function parseEntryCreateBody(body: Record<string, unknown>) {
  const consentConfirmed =
    body.consentConfirmed === undefined
      ? false
      : requireBoolean(body.consentConfirmed, 'consentConfirmed');
  const metadata = {
    kind:
      body.kind === undefined
        ? 'practice'
        : requireEnum(body.kind, 'kind', ['practice', 'teaching_lesson'] as const),
    consentConfirmedAt: consentConfirmed ? new Date() : null,
    consentScope:
      body.consentScope === undefined || body.consentScope === null
        ? null
        : requireEnum(body.consentScope, 'consentScope', ['private_course_review'] as const),
    captureProfile:
      body.captureProfile === undefined || body.captureProfile === null
        ? null
        : requireEnum(body.captureProfile, 'captureProfile', CAPTURE_PROFILES),
  };
  validateEntryMetadata(metadata);
  return {
    id: requireClientId(requireField(body.id, 'id'), 'id'),
    ...metadata,
    practiceDate: requireValidDate(body.practiceDate, 'practiceDate'),
    goalText: requireString(requireField(body.goalText, 'goalText'), 'goalText', {
      minLength: 1,
    }),
    durationSeconds: optionalDurationSeconds(body),
    tags: body.tags === undefined ? [] : normalizeTags(body.tags),
    notes:
      body.notes === undefined || body.notes === null ? null : requireString(body.notes, 'notes'),
  };
}

function isExactEntryCreateRetry(
  existing: PracticeEntry,
  entryData: ReturnType<typeof parseEntryCreateBody>,
  courseId: string,
  studentId: string
) {
  return [
    existing.deletedAt === null,
    existing.courseId === courseId,
    existing.studentId === studentId,
    existing.kind === entryData.kind,
    existing.practiceDate.getTime() === entryData.practiceDate.getTime(),
    existing.goalText === entryData.goalText,
    existing.durationSeconds === entryData.durationSeconds,
    existing.tags.length === entryData.tags.length,
    existing.tags.every((tag, index) => tag === entryData.tags[index]),
    existing.notes === entryData.notes,
    (existing.consentConfirmedAt !== null) === (entryData.consentConfirmedAt !== null),
    existing.consentScope === entryData.consentScope,
    existing.captureProfile === entryData.captureProfile,
  ].every(Boolean);
}

function hasRestrictedEntryPatchField(body: Record<string, unknown>) {
  return RESTRICTED_ENTRY_PATCH_FIELDS.some((field) => field in body);
}

function applyBasicEntryPatchFields(
  body: Record<string, unknown>,
  updateData: Record<string, unknown>
) {
  if ('goalText' in body) {
    updateData.goalText = requireString(body.goalText, 'goalText', { minLength: 1 });
  }
  if ('practiceDate' in body) {
    updateData.practiceDate = requireValidDate(body.practiceDate, 'practiceDate');
  }
  if ('durationSeconds' in body) {
    updateData.durationSeconds = nullablePatchDurationSeconds(body.durationSeconds);
  }
  if ('tags' in body) {
    updateData.tags = normalizeTags(body.tags);
  }
  if ('notes' in body) {
    updateData.notes = body.notes === null ? null : requireString(body.notes, 'notes');
  }
}

function parseConsentScope(value: unknown) {
  return value === null
    ? null
    : requireEnum(value, 'consentScope', ['private_course_review'] as const);
}

function parseCaptureProfile(value: unknown) {
  return value === null ? null : requireEnum(value, 'captureProfile', CAPTURE_PROFILES);
}

function resolvePatchMetadata(body: Record<string, unknown>, entry: EntryPatchBase) {
  const metadata = {
    kind:
      'kind' in body
        ? requireEnum(body.kind, 'kind', ['practice', 'teaching_lesson'] as const)
        : entry.kind,
    consentConfirmedAt: entry.consentConfirmedAt,
    consentScope:
      'consentScope' in body ? parseConsentScope(body.consentScope) : entry.consentScope,
    captureProfile:
      'captureProfile' in body ? parseCaptureProfile(body.captureProfile) : entry.captureProfile,
  };

  if ('consentConfirmed' in body) {
    const consentConfirmed = requireBoolean(body.consentConfirmed, 'consentConfirmed');
    // Re-sending an already-confirmed value is idempotent. In particular, the
    // iOS client includes this boolean in ordinary draft updates, which must
    // not rewrite the original consent audit timestamp.
    metadata.consentConfirmedAt = consentConfirmed
      ? (entry.consentConfirmedAt ?? new Date())
      : null;
    if (!consentConfirmed) {
      metadata.consentScope = null;
    }
  }

  validateEntryMetadata(metadata);
  return metadata;
}

function applyEntryMetadataPatch(
  body: Record<string, unknown>,
  metadata: EntryMetadata,
  updateData: Record<string, unknown>
) {
  if ('kind' in body) {
    updateData.kind = metadata.kind;
  }
  if (
    'consentScope' in body ||
    ('consentConfirmed' in body && metadata.consentConfirmedAt === null)
  ) {
    updateData.consentScope = metadata.consentScope;
  }
  if ('consentConfirmed' in body) {
    updateData.consentConfirmedAt = metadata.consentConfirmedAt;
  }
  if ('captureProfile' in body) {
    updateData.captureProfile = metadata.captureProfile;
  }
}

function parseEntryPatchBody(body: Record<string, unknown>, entry: EntryPatchBase) {
  const updateData: Record<string, unknown> = {};
  applyBasicEntryPatchFields(body, updateData);
  applyEntryMetadataPatch(body, resolvePatchMetadata(body, entry), updateData);
  return updateData;
}

function requireActiveEntry(entry: { deletedAt: Date | null }) {
  if (entry.deletedAt) {
    throw new ApiError(410, ErrorCodes.ENTRY_DELETED, 'Entry has been deleted');
  }
}

export function registerEntryRoutes(
  app: FastifyInstance,
  prisma: PrismaClient,
  requireAuth: (request: FastifyRequest) => Promise<void>
) {
  app.post('/courses/:courseId/entries', { preHandler: requireAuth }, async (request, reply) => {
    const user = request.user!;
    const courseId = (request.params as { courseId: string }).courseId;
    const role = await requireCourseRole(prisma, user.id, courseId);
    if (role !== 'student') {
      throw new ApiError(403, ErrorCodes.STUDENT_ONLY, 'Only students can create entries');
    }
    const body = requireRecord(request.body, 'body');
    const entryData = parseEntryCreateBody(body);
    try {
      const result = await prisma.$transaction(async (tx) => {
        await lockEntryIdentity(tx, entryData.id);
        const tombstone = await tx.deletedEntryTombstone.findUnique({
          where: { id: entryData.id },
        });
        if (tombstone) {
          throw new ApiError(410, ErrorCodes.ENTRY_DELETED, 'Entry ID has been deleted');
        }

        const existing = await tx.practiceEntry.findUnique({ where: { id: entryData.id } });
        if (existing) {
          if (isExactEntryCreateRetry(existing, entryData, courseId, user.id)) {
            return { entry: existing, created: false };
          }
          throw new ApiError(409, ErrorCodes.ID_CONFLICT, 'An entry with this ID already exists');
        }

        const created = await tx.practiceEntry.create({
          data: {
            id: entryData.id,
            courseId,
            studentId: user.id,
            kind: entryData.kind,
            practiceDate: entryData.practiceDate,
            goalText: entryData.goalText,
            durationSeconds: entryData.durationSeconds,
            tags: entryData.tags,
            notes: entryData.notes,
            status: 'draft',
            consentConfirmedAt: entryData.consentConfirmedAt,
            consentScope: entryData.consentScope,
            captureProfile: entryData.captureProfile,
          },
        });
        return { entry: created, created: true };
      });
      return reply.status(result.created ? 201 : 200).send(result.entry);
    } catch (error) {
      if (isPrismaError(error, 'P2002')) {
        throw new ApiError(409, ErrorCodes.ID_CONFLICT, 'An entry with this ID already exists');
      }
      throw error;
    }
  });

  app.get('/entries/:entryId', { preHandler: requireAuth }, async (request) => {
    const user = request.user!;
    const entryId = (request.params as { entryId: string }).entryId;
    const entry = await requireEntryAccess(prisma, user, entryId);
    const artifacts = await prisma.artifact.findMany({
      where: { entryId: entry.id },
      orderBy: [{ createdAt: 'asc' }, { id: 'asc' }],
    });
    const captureMarkers = await prisma.captureMarker.findMany({
      where: { entryId: entry.id },
      orderBy: [{ timeSeconds: 'asc' }, { createdAt: 'asc' }, { id: 'asc' }],
    });
    return { ...entry, artifacts, captureMarkers };
  });

  app.patch('/entries/:entryId', { preHandler: requireAuth }, async (request) => {
    const user = request.user!;
    const entryId = (request.params as { entryId: string }).entryId;
    const entry = await requireEntryAccess(prisma, user, entryId);
    await requireStudentOwner(prisma, user.id, entry, 'edit entries', entry.roleInCourse);

    const body = requireRecord(request.body, 'body');

    return withLockedEntry(prisma, entryId, async (tx, lockedEntry) => {
      requireActiveEntry(lockedEntry);
      if (lockedEntry.status !== 'draft' && hasRestrictedEntryPatchField(body)) {
        throw new ApiError(409, ErrorCodes.ENTRY_LOCKED, 'Only draft entries can be edited');
      }

      const updateData = parseEntryPatchBody(body, lockedEntry);
      return withPrismaErrors(
        () =>
          tx.practiceEntry.update({
            where: { id: entryId },
            data: updateData,
          }),
        {
          notFoundCode: ErrorCodes.ENTRY_NOT_FOUND,
          notFoundMessage: 'Entry not found',
        }
      );
    });
  });

  app.put('/entries/:entryId/capture-markers', { preHandler: requireAuth }, async (request) => {
    const user = request.user!;
    const entryId = (request.params as { entryId: string }).entryId;
    const entry = await requireEntryAccess(prisma, user, entryId);
    await requireStudentOwner(prisma, user.id, entry, 'sync capture markers', entry.roleInCourse);

    const body = requireRecord(request.body, 'body');
    const rawMarkers = requireField(body?.markers, 'markers');
    if (!Array.isArray(rawMarkers)) {
      throw new ApiError(400, ErrorCodes.VALIDATION_ERROR, 'Invalid array: markers');
    }
    if (rawMarkers.length > limits.maxMarkers) {
      throw new ApiError(
        400,
        ErrorCodes.VALIDATION_ERROR,
        `Array too large: markers (max ${limits.maxMarkers})`
      );
    }

    const markers = rawMarkers.map((raw, index) => {
      if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
        throw new ApiError(400, ErrorCodes.VALIDATION_ERROR, `Invalid object: markers[${index}]`);
      }
      const marker = raw as Record<string, unknown>;
      return {
        id: requireClientId(
          requireField(marker.id, `markers[${index}].id`),
          `markers[${index}].id`
        ),
        artifactId: requireClientId(
          requireField(marker.artifactId, `markers[${index}].artifactId`),
          `markers[${index}].artifactId`
        ),
        timeSeconds: requireNumber(
          requireField(marker.timeSeconds, `markers[${index}].timeSeconds`),
          `markers[${index}].timeSeconds`,
          { integer: true, min: 0, max: limits.maxDurationSeconds }
        ),
        kind: requireEnum(
          requireField(marker.kind, `markers[${index}].kind`),
          `markers[${index}].kind`,
          CAPTURE_MARKER_KINDS
        ),
        note:
          marker.note === undefined || marker.note === null
            ? null
            : requireString(marker.note, `markers[${index}].note`, {
                max: limits.maxMarkerTextLength,
              }),
      };
    });

    const markerIds = markers.map((marker) => marker.id);
    if (new Set(markerIds).size !== markerIds.length) {
      throw new ApiError(400, ErrorCodes.VALIDATION_ERROR, 'Duplicate capture marker IDs');
    }

    const artifactIds = Array.from(new Set(markers.map((marker) => marker.artifactId)));
    return withLockedEntry(prisma, entryId, async (tx, lockedEntry) => {
      requireActiveEntry(lockedEntry);
      if (lockedEntry.kind !== 'teaching_lesson') {
        throw new ApiError(
          400,
          ErrorCodes.VALIDATION_ERROR,
          'Capture markers are only valid for teaching lesson entries'
        );
      }
      if (lockedEntry.status === 'reviewed') {
        throw new ApiError(409, ErrorCodes.ENTRY_LOCKED, 'Reviewed entries cannot be edited');
      }

      const artifacts =
        artifactIds.length === 0
          ? []
          : await tx.artifact.findMany({
              where: { id: { in: artifactIds }, entryId: lockedEntry.id },
              select: { id: true, type: true },
            });
      const videoArtifactIds = new Set(
        artifacts.filter((artifact) => artifact.type === 'video').map((artifact) => artifact.id)
      );
      if (artifactIds.some((artifactId) => !videoArtifactIds.has(artifactId))) {
        throw new ApiError(
          404,
          ErrorCodes.ARTIFACT_NOT_FOUND,
          'Capture marker artifact not found for this entry'
        );
      }

      const existingMarkers =
        markerIds.length === 0
          ? []
          : await tx.captureMarker.findMany({
              where: { id: { in: markerIds } },
              select: { id: true, entryId: true, studentId: true },
            });
      if (
        existingMarkers.some(
          (marker) => marker.entryId !== lockedEntry.id || marker.studentId !== user.id
        )
      ) {
        throw new ApiError(
          409,
          ErrorCodes.ID_CONFLICT,
          'A capture marker with this ID belongs to another entry'
        );
      }

      for (const marker of markers) {
        await tx.captureMarker.upsert({
          where: { id: marker.id },
          create: {
            id: marker.id,
            entryId: lockedEntry.id,
            artifactId: marker.artifactId,
            studentId: user.id,
            timeSeconds: marker.timeSeconds,
            kind: marker.kind,
            note: marker.note,
          },
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
          entryId: lockedEntry.id,
          studentId: user.id,
          ...(markerIds.length > 0 ? { id: { notIn: markerIds } } : {}),
        },
      });
      return tx.captureMarker.findMany({
        where: { entryId: lockedEntry.id },
        orderBy: [{ timeSeconds: 'asc' }, { createdAt: 'asc' }, { id: 'asc' }],
      });
    });
  });

  app.delete('/entries/:entryId', { preHandler: requireAuth }, async (request, reply) => {
    const user = request.user!;
    const entryId = (request.params as { entryId: string }).entryId;
    const entry = await requireEntryAccess(prisma, user, entryId);
    await requireStudentOwner(prisma, user.id, entry, 'delete', entry.roleInCourse);

    await cascadeDeleteEntry(prisma, entryId);

    reply.status(204).send();
  });

  app.post('/entries/:entryId/submit', { preHandler: requireAuth }, async (request) => {
    const user = request.user!;
    const entryId = (request.params as { entryId: string }).entryId;
    const entry = await requireEntryAccess(prisma, user, entryId);
    await requireStudentOwner(prisma, user.id, entry, 'submit', entry.roleInCourse);
    return withLockedEntry(prisma, entryId, async (tx, lockedEntry) => {
      requireActiveEntry(lockedEntry);
      if (lockedEntry.status !== 'draft') {
        throw new ApiError(409, ErrorCodes.ENTRY_LOCKED, 'Only draft entries can be submitted');
      }
      if (
        lockedEntry.kind === 'teaching_lesson' &&
        (lockedEntry.consentConfirmedAt === null || lockedEntry.consentScope === null)
      ) {
        throw new ApiError(
          409,
          ErrorCodes.CONSENT_REQUIRED,
          'Teaching lesson entries require confirmed consent before submission'
        );
      }
      const artifacts = await tx.artifact.findMany({ where: { entryId } });
      if (artifacts.length === 0 || artifacts.some((a) => a.uploadState !== 'uploaded')) {
        throw new ApiError(
          409,
          ErrorCodes.ARTIFACTS_NOT_UPLOADED,
          'Upload artifacts before submitting'
        );
      }
      if (
        lockedEntry.kind === 'teaching_lesson' &&
        !artifacts.some((artifact) => artifact.type === 'video')
      ) {
        throw new ApiError(
          409,
          ErrorCodes.ARTIFACTS_NOT_UPLOADED,
          'Teaching lesson entries require an uploaded video artifact'
        );
      }
      return tx.practiceEntry.update({
        where: { id: entryId },
        data: { status: 'submitted' },
      });
    });
  });

  app.get('/entries/:entryId/feedback', { preHandler: requireAuth }, async (request) => {
    const user = request.user!;
    const entryId = (request.params as { entryId: string }).entryId;
    const entry = await requireEntryAccess(prisma, user, entryId);
    const feedback = await prisma.feedback.findMany({
      where: { entryId: entry.id },
      include: {
        markers: true,
        teacher: { select: { displayName: true } },
      },
      orderBy: [{ createdAt: 'asc' }, { id: 'asc' }],
    });
    return feedback.map((item) => ({
      id: item.id,
      targetType: item.targetType,
      targetId: item.targetId,
      teacherId: item.teacherId,
      teacherName: item.teacher.displayName,
      createdAt: item.createdAt,
      status: item.status,
      commentsText: item.commentsText,
      markers: item.markers,
    }));
  });
}
