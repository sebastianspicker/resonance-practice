/** Review read-model queries for versioned review adapters. */
import type { PrismaClient } from '@prisma/client';
import { requireCourseRole } from '../../courses/application/authorization.js';
import { readReviewQueuePage } from '../../entries/application/queries.js';
import {
  collectPageWithinByteBudget,
  MAX_NESTED_ROWS_PER_FETCH,
  parsePageLimit,
} from '../../../platform/http/pagination.js';
import { ApiError } from '../../../platform/http/errors.js';
import { ErrorCodes } from '../../../platform/http/errorCodes.js';
import { serializeFeedback } from './dto.js';

/** Entry statuses a teacher can list: the open queue (default) or already reviewed work. */
const REVIEW_QUEUE_STATUSES = ['submitted', 'reviewed'] as const;
type ReviewQueueStatus = (typeof REVIEW_QUEUE_STATUSES)[number];

function parseReviewQueueStatus(raw: string | undefined): ReviewQueueStatus {
  if (raw === undefined) return 'submitted';
  const status = REVIEW_QUEUE_STATUSES.find((candidate) => candidate === raw);
  if (!status) {
    throw new ApiError(400, ErrorCodes.VALIDATION_ERROR, 'status must be submitted or reviewed');
  }
  return status;
}

/**
 * Teacher-only queue of submitted (or, with `status=reviewed`, reviewed) entries
 * with student names and marker counts. Raw query values are validated after the
 * role check, as before.
 */
export async function readReviewQueue(
  prisma: PrismaClient,
  userId: string,
  courseId: string,
  query: { cursor?: string; limit?: string; status?: string }
) {
  if ((await requireCourseRole(prisma, userId, courseId)) !== 'teacher') {
    throw new ApiError(403, ErrorCodes.TEACHER_ONLY, 'Only teachers can access the review queue');
  }
  const page = await readReviewQueuePage(
    prisma,
    courseId,
    query.cursor,
    parsePageLimit(query.limit),
    parseReviewQueueStatus(query.status)
  );
  const students = await prisma.user.findMany({
    where: { id: { in: [...new Set(page.items.map((entry) => entry.studentId))] } },
    select: { id: true, displayName: true },
  });
  const names = new Map(students.map((student) => [student.id, student.displayName]));
  return {
    ...page,
    items: page.items.map((entry) => ({
      entry,
      studentName: names.get(entry.studentId) ?? '',
      captureMarkerCount: entry._count.captureMarkers,
    })),
  };
}

export async function readEntryFeedback(
  prisma: PrismaClient,
  entryId: string,
  cursor: string | undefined,
  limit: number
) {
  return collectPageWithinByteBudget(
    cursor,
    limit,
    MAX_NESTED_ROWS_PER_FETCH,
    async (batchCursor, take) => {
      const anchor = batchCursor
        ? await prisma.feedback.findFirst({
            where: { id: batchCursor, entryId },
            select: { id: true, createdAt: true },
          })
        : null;
      if (batchCursor && !anchor) {
        throw new ApiError(400, ErrorCodes.VALIDATION_ERROR, 'Invalid cursor');
      }
      return prisma.feedback.findMany({
        where: {
          entryId,
          ...(anchor
            ? {
                OR: [
                  { createdAt: { gt: anchor.createdAt } },
                  { createdAt: anchor.createdAt, id: { gt: anchor.id } },
                ],
              }
            : {}),
        },
        include: {
          markers: true,
          teacher: { select: { displayName: true } },
        },
        orderBy: [{ createdAt: 'asc' }, { id: 'asc' }],
        take,
      });
    },
    (feedback) => serializeFeedback([feedback])[0]!
  );
}
