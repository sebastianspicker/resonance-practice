import type { PrismaClient } from '@prisma/client';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { nanoid } from 'nanoid';
import { ErrorCodes } from '../../errorCodes.js';
import { ApiError, withPrismaErrors } from '../../errors.js';
import { withLockedEntry } from '../../services/entryTransaction.js';
import { requireCourseRole, requireRecord } from '../../validation.js';
import { processLockedFeedback } from './decision.js';
import { makeMarkerCreates, parseFeedbackRequest } from './parsing.js';
import { resolveFeedbackTarget } from './target.js';

export function registerFeedbackPostRoute(
  app: FastifyInstance,
  prisma: PrismaClient,
  requireAuth: (request: FastifyRequest) => Promise<void>
) {
  app.post('/feedback', { preHandler: requireAuth }, async (request, reply) => {
    const user = request.user!;
    const parsed = parseFeedbackRequest(requireRecord(request.body, 'body'));
    const target = await resolveFeedbackTarget(prisma, parsed.targetType, parsed.targetId);

    // Feedback is course-scoped. A global teacher role is not enough; the user
    // must be a teacher on the target entry's course.
    const roleInCourse = await requireCourseRole(prisma, user.id, target.courseId);
    if (roleInCourse !== 'teacher') {
      throw new ApiError(403, ErrorCodes.TEACHER_ONLY, 'Only course teachers can leave feedback');
    }

    const feedbackId = parsed.requestedFeedbackId ?? `fb_${nanoid(12)}`;
    const markerCreates = makeMarkerCreates(parsed.markers);
    const result = await withPrismaErrors(
      () =>
        withLockedEntry(prisma, target.reviewEntryId, (tx, lockedEntry) =>
          processLockedFeedback(tx, lockedEntry, {
            userId: user.id,
            requestedFeedbackId: parsed.requestedFeedbackId,
            feedbackId,
            targetType: parsed.targetType,
            targetId: parsed.targetId,
            reviewEntryId: target.reviewEntryId,
            status: parsed.status,
            commentsText: parsed.commentsText,
            markers: parsed.markers,
            markerCreates,
          })
        ),
      {
        notFoundCode: ErrorCodes.ENTRY_NOT_FOUND,
        notFoundMessage: 'Entry was deleted during feedback creation',
      }
    );
    return reply.status(result.created ? 201 : 200).send({
      ...result.feedback,
      teacherName: result.feedback.teacher.displayName,
    });
  });
}
