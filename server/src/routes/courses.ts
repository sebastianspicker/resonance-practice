import type { S3Client } from '@aws-sdk/client-s3';
import type { PrismaClient } from '@prisma/client';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { ErrorCodes } from '../errorCodes.js';
import { ApiError } from '../errors.js';
import { requireCourseRole } from '../validation.js';

/** Pagination defaults for the review queue. */
const REVIEW_QUEUE_DEFAULT_LIMIT = 20;
const REVIEW_QUEUE_MAX_LIMIT = 100;

export function registerCourseRoutes(
  app: FastifyInstance,
  prisma: PrismaClient,
  _s3: S3Client,
  requireAuth: (request: FastifyRequest) => Promise<void>
) {
  app.get('/courses', { preHandler: requireAuth }, async (request) => {
    const user = request.user!;
    const memberships = await prisma.membership.findMany({
      where: { userId: user.id },
      include: { course: true },
    });
    return memberships.map((m) => ({
      id: m.course.id,
      title: m.course.title,
      roleInCourse: m.roleInCourse,
    }));
  });

  app.get('/courses/:courseId', { preHandler: requireAuth }, async (request) => {
    const user = request.user!;
    const courseId = (request.params as { courseId: string }).courseId;
    await requireCourseRole(prisma, user.id, courseId);
    const course = await prisma.course.findUnique({ where: { id: courseId } });
    if (!course) {
      throw new ApiError(404, ErrorCodes.COURSE_NOT_FOUND, 'Course not found');
    }
    return course;
  });

  app.get('/courses/:courseId/entries', { preHandler: requireAuth }, async (request) => {
    const user = request.user!;
    const courseId = (request.params as { courseId: string }).courseId;
    const role = await requireCourseRole(prisma, user.id, courseId);

    // Optional status filter: ?status=draft | submitted | reviewed
    const validStatuses = ['draft', 'submitted', 'reviewed'] as const;
    type ValidStatus = (typeof validStatuses)[number];
    const queryStatus = (request.query as { status?: string }).status;
    if (queryStatus !== undefined && !validStatuses.includes(queryStatus as ValidStatus)) {
      throw new ApiError(
        400,
        ErrorCodes.VALIDATION_ERROR,
        `Invalid status filter: must be one of ${validStatuses.join(', ')}`
      );
    }
    const statusFilter = queryStatus as ValidStatus | undefined;

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const where: any = { courseId, deletedAt: null };
    if (role === 'teacher') {
      // Default to 'submitted' for teachers when no filter is provided
      where.status = statusFilter ?? 'submitted';
    } else {
      where.studentId = user.id;
      if (statusFilter) {
        where.status = statusFilter;
      }
    }

    const query = request.query as { cursor?: string };
    const cursor = query.cursor;

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const findOptions: any = {
      where,
      include: { artifacts: true },
      orderBy: [{ practiceDate: 'desc' }, { id: 'desc' }],
      take: 200,
    };
    if (cursor) {
      findOptions.cursor = { id: cursor };
      findOptions.skip = 1;
    }

    const entries = await prisma.practiceEntry.findMany(findOptions);
    return entries;
  });

  // BREAKING CHANGE (v0.2): Response shape changed from `[...]` to `{ items: [...], nextCursor: string | null }`.
  // iOS client must be updated to decode the new paginated envelope.
  app.get('/courses/:courseId/review-queue', { preHandler: requireAuth }, async (request) => {
    const user = request.user!;
    const courseId = (request.params as { courseId: string }).courseId;
    const role = await requireCourseRole(prisma, user.id, courseId);
    if (role !== 'teacher') {
      throw new ApiError(403, ErrorCodes.TEACHER_ONLY, 'Only teachers can access the review queue');
    }

    const query = request.query as { limit?: string; cursor?: string };

    // Parse and clamp limit
    let limit = REVIEW_QUEUE_DEFAULT_LIMIT;
    if (query.limit !== undefined) {
      const parsed = Number(query.limit);
      if (!Number.isFinite(parsed) || parsed < 1) {
        throw new ApiError(400, ErrorCodes.VALIDATION_ERROR, 'limit must be a positive integer');
      }
      limit = Math.min(Math.floor(parsed), REVIEW_QUEUE_MAX_LIMIT);
    }

    const cursor = query.cursor;

    // Build the where clause; if a cursor is provided, filter to entries
    // ordered after the cursor entry using the same sort order
    // (practiceDate desc, createdAt desc, id as tiebreaker).
    const where: Record<string, unknown> = { courseId, status: 'submitted', deletedAt: null };

    if (cursor) {
      // Look up the cursor entry to obtain its sort-key values
      const cursorEntry = await prisma.practiceEntry.findUnique({
        where: { id: cursor },
        select: { practiceDate: true, createdAt: true, id: true },
      });
      if (!cursorEntry) {
        throw new ApiError(400, ErrorCodes.VALIDATION_ERROR, 'Invalid cursor: entry not found');
      }
      // "After" in descending order means entries whose sort tuple is strictly less than the cursor's.
      // SQL equivalent: (practiceDate < cursorDate)
      //   OR (practiceDate = cursorDate AND createdAt < cursorCreatedAt)
      //   OR (practiceDate = cursorDate AND createdAt = cursorCreatedAt AND id < cursorId)
      where.OR = [
        { practiceDate: { lt: cursorEntry.practiceDate } },
        {
          practiceDate: cursorEntry.practiceDate,
          createdAt: { lt: cursorEntry.createdAt },
        },
        {
          practiceDate: cursorEntry.practiceDate,
          createdAt: cursorEntry.createdAt,
          id: { lt: cursorEntry.id },
        },
      ];
    }

    // Fetch one extra row to determine if there are more results
    const entries = await prisma.practiceEntry.findMany({
      where,
      include: {
        artifacts: true,
        student: { select: { displayName: true } },
      },
      orderBy: [{ practiceDate: 'desc' }, { createdAt: 'desc' }, { id: 'desc' }],
      take: limit + 1,
    });

    const hasMore = entries.length > limit;
    const pageEntries = hasMore ? entries.slice(0, limit) : entries;
    const lastEntry = pageEntries[pageEntries.length - 1];
    const nextCursor = hasMore && lastEntry ? lastEntry.id : null;

    return {
      items: pageEntries.map((entry) => ({
        id: entry.id,
        courseId: entry.courseId,
        studentId: entry.studentId,
        studentName: entry.student.displayName,
        practiceDate: entry.practiceDate,
        goalText: entry.goalText,
        notes: entry.notes,
        artifacts: entry.artifacts,
      })),
      nextCursor,
    };
  });
}
