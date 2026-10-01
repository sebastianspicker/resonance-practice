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

/** Require one exact course role; the 403 code names the role that was required. */
export async function requireCourseMembership(
  db: Prisma.TransactionClient,
  userId: string,
  courseId: string,
  requiredRole: CourseRole,
  message: string
): Promise<void> {
  if ((await findCourseRole(db, userId, courseId)) !== requiredRole) {
    throw new ApiError(
      403,
      requiredRole === 'teacher' ? ErrorCodes.TEACHER_ONLY : ErrorCodes.STUDENT_ONLY,
      message
    );
  }
}

export async function requireCourseRole(prisma: PrismaClient, userId: string, courseId: string) {
  const roleInCourse = await findCourseRole(prisma, userId, courseId);
  if (!roleInCourse) {
    throw new ApiError(403, ErrorCodes.COURSE_ACCESS_DENIED, 'User is not a member of this course');
  }
  return roleInCourse;
}
