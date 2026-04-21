import type { S3Client } from '@aws-sdk/client-s3';
import type { PrismaClient } from '@prisma/client';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { nanoid } from 'nanoid';
import { limits } from '../config.js';
import { ErrorCodes } from '../errorCodes.js';
import { ApiError, withPrismaErrors } from '../errors.js';
import {
  requireCourseRole,
  requireEnum,
  requireField,
  requireNumber,
  requireString,
} from '../validation.js';

export function registerFeedbackRoutes(
  app: FastifyInstance,
  prisma: PrismaClient,
  _s3: S3Client,
  requireAuth: (request: FastifyRequest) => Promise<void>
) {
  app.post('/feedback', { preHandler: requireAuth }, async (request, reply) => {
    const user = request.user!;
    const body = request.body as Record<string, unknown>;
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
      { max: limits.maxCommentsTextLength }
    );
    const markers = Array.isArray(body?.markers) ? (body.markers as Record<string, unknown>[]) : [];
    if (markers.length > limits.maxMarkers) {
      throw new ApiError(
        400,
        ErrorCodes.VALIDATION_ERROR,
        `Too many markers (max ${limits.maxMarkers})`
      );
    }
    for (const marker of markers) {
      requireNumber(marker?.timeSeconds, 'marker.timeSeconds', {
        min: 0,
        max: limits.maxMarkerTimeSeconds,
      });
      requireString(requireField(marker?.text, 'marker.text'), 'marker.text', {
        max: limits.maxMarkerTextLength,
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

    // Use course role for authorization - only course teachers can leave feedback
    const roleInCourse = await requireCourseRole(prisma, user.id, courseId);
    if (roleInCourse !== 'teacher') {
      throw new ApiError(403, ErrorCodes.TEACHER_ONLY, 'Only course teachers can leave feedback');
    }

    const feedbackId = `fb_${nanoid(12)}`;
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
                create: markers.map((marker: Record<string, unknown>) => ({
                  id: `mk_${nanoid(10)}`,
                  timeSeconds: marker.timeSeconds as number,
                  text: marker.text as string,
                })),
              },
            },
            include: { markers: true, teacher: true },
          });

          // Design: Any feedback (entry-level or artifact-level) marks the entry as reviewed
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
