import type { PrismaClient } from '@prisma/client';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { nanoid } from 'nanoid';
import { limits } from '../config.js';
import { ErrorCodes } from '../errorCodes.js';
import { ApiError, withPrismaErrors } from '../errors.js';
import {
  requireCourseRole,
  requireClientId,
  requireEnum,
  requireField,
  requireNumber,
  requireString,
} from '../validation.js';

export function registerFeedbackRoutes(
  app: FastifyInstance,
  prisma: PrismaClient,
  requireAuth: (request: FastifyRequest) => Promise<void>
) {
  app.post('/feedback', { preHandler: requireAuth }, async (request, reply) => {
    const user = request.user!;
    const body = request.body as Record<string, unknown>;
    const requestedFeedbackId = body?.id === undefined ? undefined : requireClientId(body.id, 'id');
    const targetType = requireEnum(requireField(body?.targetType, 'targetType'), 'targetType', [
      'entry',
      'artifact',
    ] as const);
    const targetId = requireString(requireField(body?.targetId, 'targetId'), 'targetId');
    const status = requireEnum(requireField(body?.status, 'status'), 'status', [
      'ok',
      'needs_revision',
      'next_goal',
    ] as const);
    const commentsText = requireString(
      requireField(body?.commentsText, 'commentsText'),
      'commentsText',
      { minLength: 1, max: limits.maxCommentsTextLength }
    );
    const rawMarkers = Array.isArray(body?.markers)
      ? (body.markers as Record<string, unknown>[])
      : [];
    if (rawMarkers.length > limits.maxMarkers) {
      throw new ApiError(
        400,
        ErrorCodes.VALIDATION_ERROR,
        `Too many markers (max ${limits.maxMarkers})`
      );
    }
    const markers: Array<{ timeSeconds: number; text: string }> = [];
    for (let index = 0; index < limits.maxMarkers; index += 1) {
      if (index >= rawMarkers.length) break;
      const marker = rawMarkers[index]!;
      markers.push({
        timeSeconds: requireNumber(marker?.timeSeconds, 'marker.timeSeconds', {
          integer: true,
          min: 0,
          max: limits.maxMarkerTimeSeconds,
        }),
        text: requireString(requireField(marker?.text, 'marker.text'), 'marker.text', {
          max: limits.maxMarkerTextLength,
        }),
      });
    }

    let courseId: string;
    let reviewEntryId: string;
    if (targetType === 'entry') {
      const entry = await prisma.practiceEntry.findUnique({ where: { id: targetId } });
      if (!entry) {
        throw new ApiError(404, ErrorCodes.ENTRY_NOT_FOUND, 'Entry not found');
      }
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
      courseId = entry.courseId;
      reviewEntryId = entry.id;
    } else if (targetType === 'artifact') {
      const artifact = await prisma.artifact.findUnique({
        where: { id: targetId },
        include: { entry: true },
      });
      if (!artifact) {
        throw new ApiError(404, ErrorCodes.ARTIFACT_NOT_FOUND, 'Artifact not found');
      }
      if (artifact.entry.deletedAt) {
        throw new ApiError(410, ErrorCodes.ENTRY_DELETED, 'Entry has been deleted');
      }
      if (artifact.entry.status === 'draft') {
        throw new ApiError(
          409,
          ErrorCodes.ENTRY_NOT_SUBMITTED,
          'Entry must be submitted before feedback can be added'
        );
      }
      courseId = artifact.entry.courseId;
      reviewEntryId = artifact.entry.id;
    } else {
      throw new ApiError(400, ErrorCodes.INVALID_TARGET, 'Invalid target type');
    }

    // Feedback is course-scoped. A global teacher role is not enough; the user
    // must be a teacher on the target entry's course.
    const roleInCourse = await requireCourseRole(prisma, user.id, courseId);
    if (roleInCourse !== 'teacher') {
      throw new ApiError(403, ErrorCodes.TEACHER_ONLY, 'Only course teachers can leave feedback');
    }

    const feedbackId = requestedFeedbackId ?? `fb_${nanoid(12)}`;
    const existingFeedback = requestedFeedbackId
      ? await prisma.feedback.findUnique({
          where: { id: requestedFeedbackId },
          include: { markers: true, teacher: true },
        })
      : null;
    if (existingFeedback) {
      if (
        existingFeedback.teacherId !== user.id ||
        existingFeedback.targetType !== targetType ||
        existingFeedback.targetId !== targetId ||
        existingFeedback.entryId !== reviewEntryId ||
        !feedbackBodyMatches(existingFeedback, { status, commentsText, markers })
      ) {
        throw new ApiError(409, ErrorCodes.ID_CONFLICT, 'Feedback ID already exists');
      }
      return reply.status(200).send({
        ...existingFeedback,
        teacherName: existingFeedback.teacher.displayName,
      });
    }

    const markerCreates: Array<{ id: string; timeSeconds: number; text: string }> = [];
    for (let index = 0; index < limits.maxMarkers; index += 1) {
      if (index >= markers.length) break;
      const marker = markers[index]!;
      markerCreates.push({
        id: `mk_${nanoid(10)}`,
        timeSeconds: marker.timeSeconds,
        text: marker.text,
      });
    }

    const feedback = await withPrismaErrors(
      () =>
        prisma.$transaction(async (tx) => {
          const created = await tx.feedback.create({
            data: {
              id: feedbackId,
              targetType,
              targetId,
              teacherId: user.id,
              entryId: reviewEntryId,
              status,
              commentsText,
              markers: {
                create: markerCreates,
              },
            },
            include: { markers: true, teacher: true },
          });

          // Product rule: any teacher feedback, whether on the entry or one of
          // its artifacts, marks the parent entry as reviewed.
          await tx.practiceEntry.update({
            where: { id: reviewEntryId },
            data: { status: 'reviewed' },
          });

          return created;
        }),
      {
        notFoundCode: ErrorCodes.ENTRY_NOT_FOUND,
        notFoundMessage: 'Entry was deleted during feedback creation',
      }
    );
    return reply.status(201).send({
      ...feedback,
      teacherName: feedback.teacher.displayName,
    });
  });
}

function feedbackBodyMatches(
  existingFeedback: {
    status: string;
    commentsText: string;
    markers: Array<{ timeSeconds: number; text: string }>;
  },
  requested: {
    status: string;
    commentsText: string;
    markers: Array<{ timeSeconds: number; text: string }>;
  }
): boolean {
  if (
    existingFeedback.status !== requested.status ||
    existingFeedback.commentsText !== requested.commentsText
  ) {
    return false;
  }

  return markerSetsMatch(existingFeedback.markers, requested.markers);
}

function markerSetsMatch(
  existingMarkers: Array<{ timeSeconds: number; text: string }>,
  requestedMarkers: Array<{ timeSeconds: number; text: string }>
): boolean {
  if (existingMarkers.length !== requestedMarkers.length) {
    return false;
  }
  if (existingMarkers.length > limits.maxMarkers) {
    return false;
  }

  const existing = normalizeMarkers(existingMarkers);
  const requested = normalizeMarkers(requestedMarkers);
  return existing.every(
    (marker, index) =>
      marker.timeSeconds === requested[index]?.timeSeconds && marker.text === requested[index]?.text
  );
}

function normalizeMarkers(markers: Array<{ timeSeconds: number; text: string }>) {
  const normalized: Array<{ timeSeconds: number; text: string }> = [];
  for (let index = 0; index < limits.maxMarkers; index += 1) {
    if (index >= markers.length) break;
    const marker = markers[index]!;
    normalized.push({ timeSeconds: marker.timeSeconds, text: marker.text });
  }
  return normalized.sort((a, b) => a.timeSeconds - b.timeSeconds || a.text.localeCompare(b.text));
}
