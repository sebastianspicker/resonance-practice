/** Versioned course lists. Course membership authorization stays in this module. */
import type { PrismaClient } from '@prisma/client';
import type { FastifyInstance, FastifyRequest } from 'fastify';

export function registerCourseRoutes(
  app: FastifyInstance,
  prisma: PrismaClient,
  requireAuth: (request: FastifyRequest) => Promise<void>
) {
  app.get('/api/v1/courses', { preHandler: requireAuth }, async (request) => {
    const memberships = await prisma.membership.findMany({
      where: { userId: request.user!.id },
      include: { course: true },
      orderBy: { courseId: 'asc' },
    });
    return memberships.map((membership) => ({
      id: membership.course.id,
      title: membership.course.title,
      roleInCourse: membership.roleInCourse,
    }));
  });
}
