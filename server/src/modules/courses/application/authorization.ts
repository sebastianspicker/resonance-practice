/** Course-membership authorization stays with the course aggregate. */
import type { CourseRole, Prisma, PrismaClient } from '@prisma/client';
import { ErrorCodes } from '../../../platform/http/errorCodes.js';
import { ApiError } from '../../../platform/http/errors.js';

export async function findCourseRole(
  db: Prisma.TransactionClient,
  userId: string,
  courseId: string
): Promise<CourseRole | null> {
  const membership = await db.membership.findUnique({
    where: { userId_courseId: { userId, courseId } },
  });
  return membership?.roleInCourse ?? null;
}

export async function requireCourseRole(prisma: PrismaClient, userId: string, courseId: string) {
  const roleInCourse = await findCourseRole(prisma, userId, courseId);
  if (!roleInCourse) {
    throw new ApiError(403, ErrorCodes.COURSE_ACCESS_DENIED, 'User is not a member of this course');
  }
  return roleInCourse;
}
