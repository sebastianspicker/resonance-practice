/** Entry CRUD routes, including optimistic-version and cascade boundaries. */
import type { PrismaClient } from '@prisma/client';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { limits } from '../config.js';
import { ErrorCodes } from '../errorCodes.js';
import { ApiError, isPrismaError, withPrismaErrors } from '../errors.js';
import { cascadeDeleteEntry } from '../services/entryCascade.js';
import { lockEntryIdentity, withLockedEntry } from '../services/entryTransaction.js';
import {
  CAPTURE_MARKER_KINDS,
  hasRestrictedEntryPatchField,
  isExactEntryCreateRetry,
  parseEntryCreateBody,
  parseEntryPatchBody,
  requireActiveEntry,
} from './entries/parsing.js';
import { serializeFeedback } from './feedbackSerialization.js';
import {
  requireClientId,
  requireCourseRole,
  requireEntryAccess,
  requireEnum,
  requireField,
  requireNumber,
  requireRecord,
  requireString,
  requireStudentOwner,
} from '../validation.js';

export async function readEntryFeedback(prisma: PrismaClient, entryId: string) {
  return prisma.feedback.findMany({
    where: { entryId },
    include: {
      markers: true,
      teacher: { select: { displayName: true } },
    },
    orderBy: [{ createdAt: 'asc' }, { id: 'asc' }],
  });
}

export function registerEntryRoutes(
  app: FastifyInstance,
  prisma: PrismaClient,
  requireAuth: (request: FastifyRequest) => Promise<void>
) {
  registerEntryCrudRoutes(app, prisma, requireAuth);
  registerCaptureMarkerRoute(app, prisma, requireAuth);
  registerEntryLifecycleRoutes(app, prisma, requireAuth);
}

function registerEntryCrudRoutes(
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
            data: { ...updateData, version: { increment: 1 } },
          }),
        {
          notFoundCode: ErrorCodes.ENTRY_NOT_FOUND,
          notFoundMessage: 'Entry not found',
        }
      );
    });
  });
}

function registerCaptureMarkerRoute(
  app: FastifyInstance,
  prisma: PrismaClient,
  requireAuth: (request: FastifyRequest) => Promise<void>
) {
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
      await tx.practiceEntry.update({
        where: { id: lockedEntry.id },
        data: { version: { increment: 1 } },
      });
      return tx.captureMarker.findMany({
        where: { entryId: lockedEntry.id },
        orderBy: [{ timeSeconds: 'asc' }, { createdAt: 'asc' }, { id: 'asc' }],
      });
    });
  });
}

function registerEntryLifecycleRoutes(
  app: FastifyInstance,
  prisma: PrismaClient,
  requireAuth: (request: FastifyRequest) => Promise<void>
) {
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
        data: { status: 'submitted', version: { increment: 1 } },
      });
    });
  });

  app.get('/entries/:entryId/feedback', { preHandler: requireAuth }, async (request) => {
    const user = request.user!;
    const entryId = (request.params as { entryId: string }).entryId;
    const entry = await requireEntryAccess(prisma, user, entryId);
    const feedback = await readEntryFeedback(prisma, entry.id);
    return serializeFeedback(feedback, true);
  });
}
