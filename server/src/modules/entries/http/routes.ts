/** Versioned entry read adapter. Mutations are v1 sync commands. */
import type { PrismaClient } from '@prisma/client';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { requireCourseRole } from '../../courses/application/authorization.js';
import { readAccessibleEntry, readEntryPage } from '../application/queries.js';
import { parsePageLimit } from '../../../platform/http/pagination.js';
import { toEntryResponseDto } from '../application/dto.js';
import { ErrorCodes } from '../../../platform/http/errorCodes.js';
import { ApiError } from '../../../platform/http/errors.js';
import { requireClientId, requireEnum } from '../../../platform/http/input.js';

const ENTRY_STATUSES = ['draft', 'submitted', 'reviewed'] as const;

export function registerEntryRoutes(
  app: FastifyInstance,
  prisma: PrismaClient,
  requireAuth: (request: FastifyRequest) => Promise<void>
) {
  app.get('/api/v1/courses/:courseId/entries', { preHandler: requireAuth }, async (request) => {
    const courseId = requireClientId((request.params as { courseId: string }).courseId, 'courseId');
    const role = await requireCourseRole(prisma, request.user!.id, courseId);
    const query = request.query as { status?: string; cursor?: string; limit?: string };
    const status =
      query.status === undefined ? undefined : requireEnum(query.status, 'status', ENTRY_STATUSES);
    if (role === 'teacher' && status === 'draft') {
      throw new ApiError(
        403,
        ErrorCodes.ENTRY_ACCESS_DENIED,
        'Draft entries are not visible to teachers'
      );
    }
    const page = await readEntryPage(
      prisma,
      {
        courseId,
        deletedAt: null,
        ...(role === 'student'
          ? { studentId: request.user!.id, ...(status ? { status } : {}) }
          : { status: status ?? 'submitted' }),
      },
      query.cursor,
      parsePageLimit(query.limit)
    );
    return { ...page, items: page.items.map(toEntryResponseDto) };
  });

  app.get('/api/v1/entries/:entryId', { preHandler: requireAuth }, async (request) => {
    const entryId = requireClientId((request.params as { entryId: string }).entryId, 'entryId');
    return toEntryResponseDto(await readAccessibleEntry(prisma, request.user!.id, entryId));
  });
}
