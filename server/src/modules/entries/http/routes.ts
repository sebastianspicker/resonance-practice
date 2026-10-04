/** Versioned entry read adapter. Mutations are v1 sync commands. */
import type { PrismaClient } from '@prisma/client';
import type { FastifyInstance } from 'fastify';
import { authenticatedUser, type RequireAuth } from '../../../platform/http/authentication.js';
import { listCourseEntries, readAccessibleEntry } from '../application/queries.js';
import { toEntryResponseDto } from '../application/dto.js';
import { requireClientId } from '../../../platform/http/input.js';
import { fitPageToByteBudget } from '../../../platform/http/pagination.js';
import {
  apiLimiter,
  apiRateLimit,
  rejectRateLimited,
  requestCost,
} from '../../../platform/http/rateLimit.js';

export function registerEntryRoutes(
  app: FastifyInstance,
  prisma: PrismaClient,
  requireAuth: RequireAuth
) {
  app.get(
    '/api/v1/courses/:courseId/entries',
    { preHandler: requireAuth, config: { rateLimit: apiRateLimit } },
    async (request) => {
      await apiLimiter.consume(request.ip, requestCost(request)).catch(rejectRateLimited);
      const courseId = requireClientId(
        (request.params as { courseId: string }).courseId,
        'courseId'
      );
      const page = await listCourseEntries(
        prisma,
        authenticatedUser(request).id,
        courseId,
        request.query as { status?: string; cursor?: string; limit?: string }
      );
      return fitPageToByteBudget({ ...page, items: page.items.map(toEntryResponseDto) });
    }
  );

  app.get(
    '/api/v1/entries/:entryId',
    { preHandler: requireAuth, config: { rateLimit: apiRateLimit } },
    async (request) => {
      await apiLimiter.consume(request.ip, requestCost(request)).catch(rejectRateLimited);
      const entryId = requireClientId((request.params as { entryId: string }).entryId, 'entryId');
      return toEntryResponseDto(
        await readAccessibleEntry(prisma, authenticatedUser(request).id, entryId)
      );
    }
  );
}
