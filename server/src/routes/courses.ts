import type { Prisma, PrismaClient } from '@prisma/client';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { ErrorCodes } from '../errorCodes.js';
import { ApiError } from '../errors.js';
import { requireCourseRole } from '../validation.js';

/** Pagination defaults for the review queue. */
const REVIEW_QUEUE_DEFAULT_LIMIT = 20;
const REVIEW_QUEUE_MAX_LIMIT = 100;

/** Pagination defaults for the entries list. */
const ENTRIES_DEFAULT_LIMIT = 50;
const ENTRIES_MAX_LIMIT = 200;

// ── Cursor-pagination helpers ────────────────────────────────────────

/**
 * Parse and clamp a `limit` query parameter.
 * Returns the clamped limit or the provided default when the param is absent.
 */
function parseLimitParam(raw: string | undefined, defaultLimit: number, maxLimit: number): number {
  if (raw === undefined) return defaultLimit;
  const parsed = Number(raw);
  if (!Number.isFinite(parsed) || parsed < 1) {
    throw new ApiError(400, ErrorCodes.VALIDATION_ERROR, 'limit must be a positive integer');
  }
  return Math.min(Math.floor(parsed), maxLimit);
}

/**
 * Look up a cursor entry and build a Prisma `OR` clause that selects only entries
 * ordered strictly after the cursor in (practiceDate DESC, createdAt DESC, id DESC) order.
 * Returns `undefined` when no cursor is provided.
 */
async function buildCursorWhere(
  prisma: PrismaClient,
  cursor: string | undefined
): Promise<Prisma.PracticeEntryWhereInput['OR'] | undefined> {
  if (!cursor) return undefined;

  const cursorEntry = await prisma.practiceEntry.findUnique({
    where: { id: cursor },
    select: { practiceDate: true, createdAt: true, id: true },
  });
  if (!cursorEntry) {
    throw new ApiError(400, ErrorCodes.VALIDATION_ERROR, 'Invalid cursor: entry not found');
  }

  // "After" in descending order means entries whose sort tuple is strictly less than the cursor's.
  return [
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

// ────────────────────────────────────────────────────────────────────

export function registerCourseRoutes(
  app: FastifyInstance,
  prisma: PrismaClient,
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

  // BREAKING CHANGE (v0.2): Response shape changed from `[...]` to `{ items: [...], nextCursor: string | null }`.
  // iOS client must be updated to decode the new paginated envelope.
  app.get('/courses/:courseId/entries', { preHandler: requireAuth }, async (request) => {
    const user = request.user!;
    const courseId = (request.params as { courseId: string }).courseId;
    const role = await requireCourseRole(prisma, user.id, courseId);

    // Optional status filter: ?status=draft | submitted | reviewed
    const validStatuses = ['draft', 'submitted', 'reviewed'] as const;
    type ValidStatus = (typeof validStatuses)[number];
    const queryParams = request.query as { status?: string; limit?: string; cursor?: string };
    const queryStatus = queryParams.status;
    if (queryStatus !== undefined && !validStatuses.includes(queryStatus as ValidStatus)) {
      throw new ApiError(
        400,
        ErrorCodes.VALIDATION_ERROR,
        `Invalid status filter: must be one of ${validStatuses.join(', ')}`
      );
    }
    const statusFilter = queryStatus as ValidStatus | undefined;

    const limit = parseLimitParam(queryParams.limit, ENTRIES_DEFAULT_LIMIT, ENTRIES_MAX_LIMIT);
    const cursor = queryParams.cursor;

    const where: Prisma.PracticeEntryWhereInput = { courseId, deletedAt: null };
    if (role === 'teacher') {
      where.status = statusFilter ?? 'submitted';
    } else {
      where.studentId = user.id;
      if (statusFilter) {
        where.status = statusFilter;
      }
    }

    const cursorOR = await buildCursorWhere(prisma, cursor);
    if (cursorOR) where.OR = cursorOR;

    const entries = await prisma.practiceEntry.findMany({
      where,
      include: { artifacts: true },
      orderBy: [{ practiceDate: 'desc' }, { createdAt: 'desc' }, { id: 'desc' }],
      take: limit + 1,
    });

    const hasMore = entries.length > limit;
    const pageEntries = hasMore ? entries.slice(0, limit) : entries;
    const lastEntry = pageEntries[pageEntries.length - 1];
    const nextCursor = hasMore && lastEntry ? lastEntry.id : null;

    return { items: pageEntries, nextCursor };
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

    const { limit: limitParam, cursor } = request.query as { limit?: string; cursor?: string };
    const limit = parseLimitParam(limitParam, REVIEW_QUEUE_DEFAULT_LIMIT, REVIEW_QUEUE_MAX_LIMIT);

    // Build the where clause; if a cursor is provided, filter to entries
    // ordered after the cursor entry using the same sort order
    // (practiceDate desc, createdAt desc, id as tiebreaker).
    const where: Prisma.PracticeEntryWhereInput = {
      courseId,
      status: 'submitted',
      deletedAt: null,
    };

    const cursorOR = await buildCursorWhere(prisma, cursor);
    if (cursorOR) where.OR = cursorOR;

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
        tags: entry.tags,
        durationSeconds: entry.durationSeconds,
        status: entry.status,
        artifacts: entry.artifacts,
      })),
      nextCursor,
    };
  });
}
