/** Versioned course lists. Course membership authorization stays in this module. */
import type { PrismaClient } from '@prisma/client';
import type { FastifyInstance } from 'fastify';
import { authenticatedUser, type RequireAuth } from '../../../platform/http/authentication.js';
import { apiRateLimit } from '../../../platform/http/rateLimit.js';

export function registerCourseRoutes(
  app: FastifyInstance,
  prisma: PrismaClient,
  requireAuth: RequireAuth
) {
  app.get(
    '/api/v1/courses',
    { preHandler: requireAuth, config: { rateLimit: apiRateLimit } },
    async (request) => {
      const memberships = await prisma.membership.findMany({
        where: { userId: authenticatedUser(request).id },
        include: { course: true },
        orderBy: { courseId: 'asc' },
      });
      return memberships.map((membership) => ({
        id: membership.course.id,
        title: membership.course.title,
        roleInCourse: membership.roleInCourse,
      }));
    }
  );
}
