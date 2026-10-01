/** Versioned review reads. Review creation is a v1 sync command. */
import type { PrismaClient } from '@prisma/client';
import type { FastifyInstance } from 'fastify';
import { authenticatedUser, type RequireAuth } from '../../../platform/http/authentication.js';
import { readAccessibleEntryIdentity } from '../../entries/application/queries.js';
import { toEntrySummaryDto } from '../../entries/application/dto.js';
import { parsePageLimit } from '../../../platform/http/pagination.js';
import { requireClientId } from '../../../platform/http/input.js';
import { serializeFeedback } from '../application/dto.js';
import { readEntryFeedback, readReviewQueue } from '../application/queries.js';

export function registerReviewRoutes(
  app: FastifyInstance,
  prisma: PrismaClient,
  requireAuth: RequireAuth
) {
  app.get(
    '/api/v1/courses/:courseId/review-queue',
    { preHandler: requireAuth },
    async (request) => {
      const courseId = requireClientId(
        (request.params as { courseId: string }).courseId,
        'courseId'
      );
      const page = await readReviewQueue(
        prisma,
        authenticatedUser(request).id,
        courseId,
        request.query as { cursor?: string; limit?: string }
      );
      return {
        ...page,
        items: page.items.map(({ entry, studentName, captureMarkerCount }) => ({
          ...toEntrySummaryDto(entry),
          studentName,
          captureMarkerCount,
        })),
      };
    }
  );

  app.get('/api/v1/entries/:entryId/feedback', { preHandler: requireAuth }, async (request) => {
    const entry = await readAccessibleEntryIdentity(
      prisma,
      authenticatedUser(request).id,
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
