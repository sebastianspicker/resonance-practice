/** Course-membership authorization stays with the course aggregate. */
import type { PrismaClient } from '@prisma/client';
import { ErrorCodes } from '../../../platform/http/errorCodes.js';
import { ApiError } from '../../../platform/http/errors.js';

export async function requireCourseRole(prisma: PrismaClient, userId: string, courseId: string) {
  const membership = await prisma.membership.findUnique({
    where: { userId_courseId: { userId, courseId } },
  });
  if (!membership) {
    throw new ApiError(403, ErrorCodes.COURSE_ACCESS_DENIED, 'User is not a member of this course');
  }
  return membership.roleInCourse;
}
