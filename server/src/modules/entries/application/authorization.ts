/** Entry visibility and ownership authorization. */
import type { Prisma, PrismaClient } from '@prisma/client';
import { findCourseRole, requireCourseRole } from '../../courses/application/authorization.js';
import { ErrorCodes } from '../../../platform/http/errorCodes.js';
import { ApiError } from '../../../platform/http/errors.js';

export async function requireVisibleCourseEntry(
  prisma: PrismaClient,
  userId: string,
  entry: { courseId: string; studentId: string; status: string }
) {
  const roleInCourse = await requireCourseRole(prisma, userId, entry.courseId);
  if (roleInCourse === 'student' && entry.studentId !== userId) {
    throw new ApiError(403, ErrorCodes.ENTRY_ACCESS_DENIED, 'Entry does not belong to student');
  }
  if (roleInCourse === 'teacher' && entry.status === 'draft') {
    throw new ApiError(
      403,
      ErrorCodes.ENTRY_ACCESS_DENIED,
      'Draft entries are not visible to teachers'
    );
  }
  return roleInCourse;
}

/** Only the entry's student, while still a course student, may perform the action. */
export async function requireStudentOwner(
  tx: Prisma.TransactionClient,
  userId: string,
  entry: { courseId: string; studentId: string },
  action: string
): Promise<void> {
  const roleInCourse = await findCourseRole(tx, userId, entry.courseId);
  if (roleInCourse !== 'student' || entry.studentId !== userId) {
    throw new ApiError(403, ErrorCodes.STUDENT_ONLY, `Only the student owner can ${action}`);
  }
}
