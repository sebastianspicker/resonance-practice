import type { PrismaClient } from '@prisma/client';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { limits } from '../../config.js';
import { ErrorCodes } from '../../errorCodes.js';
import { ApiError } from '../../errors.js';
import { withLockedEntry } from '../../services/entryTransaction.js';
import { CAPTURE_MARKER_KINDS, requireActiveEntry } from './parsing.js';
import {
  requireClientId,
  requireEntryAccess,
  requireEnum,
  requireField,
  requireNumber,
  requireRecord,
  requireString,
  requireStudentOwner,
} from '../../validation.js';

export function registerCaptureMarkerRoute(
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
