/** Versioned review reads. Review creation is a v1 sync command. */
import type { PrismaClient } from '@prisma/client';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { requireCourseRole } from '../../courses/application/authorization.js';
import {
  readAccessibleEntryIdentity,
  readReviewQueuePage,
} from '../../entries/application/queries.js';
import { toEntrySummaryDto } from '../../entries/application/dto.js';
import { parsePageLimit } from '../../../platform/http/pagination.js';
import { ErrorCodes } from '../../../platform/http/errorCodes.js';
import { ApiError } from '../../../platform/http/errors.js';
import { requireClientId } from '../../../platform/http/input.js';
import { serializeFeedback } from '../application/dto.js';
import { readEntryFeedback } from '../application/queries.js';

export function registerReviewRoutes(
  app: FastifyInstance,
  prisma: PrismaClient,
  requireAuth: (request: FastifyRequest) => Promise<void>
) {
  app.get(
    '/api/v1/courses/:courseId/review-queue',
    { preHandler: requireAuth },
    async (request) => {
      const courseId = requireClientId(
        (request.params as { courseId: string }).courseId,
        'courseId'
      );
      if ((await requireCourseRole(prisma, request.user!.id, courseId)) !== 'teacher') {
        throw new ApiError(
          403,
          ErrorCodes.TEACHER_ONLY,
          'Only teachers can access the review queue'
        );
      }
      const query = request.query as { cursor?: string; limit?: string };
      const page = await readReviewQueuePage(
        prisma,
        courseId,
        query.cursor,
        parsePageLimit(query.limit)
      );
      const students = await prisma.user.findMany({
        where: { id: { in: [...new Set(page.items.map((entry) => entry.studentId))] } },
        select: { id: true, displayName: true },
      });
      const names = new Map(students.map((student) => [student.id, student.displayName]));
      return {
        ...page,
        items: page.items.map((entry) => ({
          ...toEntrySummaryDto(entry),
          studentName: names.get(entry.studentId) ?? '',
          captureMarkerCount: entry._count.captureMarkers,
        })),
      };
    }
  );

  app.get('/api/v1/entries/:entryId/feedback', { preHandler: requireAuth }, async (request) => {
    const entry = await readAccessibleEntryIdentity(
      prisma,
      request.user!.id,
      requireClientId((request.params as { entryId: string }).entryId, 'entryId')
    );
    const query = request.query as { cursor?: string; limit?: string };
    const page = await readEntryFeedback(
      prisma,
      entry.id,
      query.cursor,
      parsePageLimit(query.limit)
    );
    return { ...page, items: serializeFeedback(page.items) };
  });
}
