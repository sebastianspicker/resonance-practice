/** Entry read projections shared by v1 entry and review adapters. */
import type { Prisma, PrismaClient } from '@prisma/client';
import { requireCourseRole } from '../../courses/application/authorization.js';
import { requireVisibleCourseEntry } from './authorization.js';
import { ErrorCodes } from '../../../platform/http/errorCodes.js';
import { ApiError } from '../../../platform/http/errors.js';
import { requireEnum } from '../../../platform/http/input.js';
import { cursorPage, parsePageLimit } from '../../../platform/http/pagination.js';

const ENTRY_STATUSES = ['draft', 'submitted', 'reviewed'] as const;

export async function readAccessibleEntry(prisma: PrismaClient, userId: string, entryId: string) {
  const entry = await prisma.practiceEntry.findUnique({
    where: { id: entryId },
    include: { artifacts: true, captureMarkers: true },
  });
  if (!entry) throw new ApiError(404, ErrorCodes.ENTRY_NOT_FOUND, 'Entry not found');
  await requireVisibleCourseEntry(prisma, userId, entry);
  return entry;
}

/** Authorize related reads without fetching media that the response will not use. */
export async function readAccessibleEntryIdentity(
  prisma: PrismaClient,
  userId: string,
  entryId: string
) {
  const entry = await prisma.practiceEntry.findUnique({
    where: { id: entryId },
    select: { id: true, courseId: true, studentId: true, status: true },
  });
  if (!entry) throw new ApiError(404, ErrorCodes.ENTRY_NOT_FOUND, 'Entry not found');
  await requireVisibleCourseEntry(prisma, userId, entry);
  return entry;
}

/**
 * List course entries visible to the caller: students see their own entries,
 * teachers see submitted or reviewed entries but never drafts. Raw query values
 * are validated after membership so authorization errors keep precedence.
 */
export async function listCourseEntries(
  prisma: PrismaClient,
  userId: string,
  courseId: string,
  query: { status?: string; cursor?: string; limit?: string }
) {
  const role = await requireCourseRole(prisma, userId, courseId);
  const status =
    query.status === undefined ? undefined : requireEnum(query.status, 'status', ENTRY_STATUSES);
  if (role === 'teacher' && status === 'draft') {
    throw new ApiError(
      403,
      ErrorCodes.ENTRY_ACCESS_DENIED,
      'Draft entries are not visible to teachers'
    );
  }
  return readEntryPage(
    prisma,
    {
      courseId,
      deletedAt: null,
      ...(role === 'student'
        ? { studentId: userId, ...(status ? { status } : {}) }
        : { status: status ?? 'submitted' }),
    },
    query.cursor,
    parsePageLimit(query.limit)
  );
}

async function readEntryPage(
  prisma: PrismaClient,
  visibleWhere: Prisma.PracticeEntryWhereInput,
  cursor: string | undefined,
  limit: number
) {
  const entries = await prisma.practiceEntry.findMany({
    ...(await entryPageQuery(prisma, visibleWhere, cursor, limit)),
    include: { artifacts: true, captureMarkers: true },
  });
  return cursorPage(entries, limit);
}

/** Review lists need marker counts, while detail reads retain the complete collection. */
export async function readReviewQueuePage(
  prisma: PrismaClient,
  courseId: string,
  cursor: string | undefined,
  limit: number
) {
  const entries = await prisma.practiceEntry.findMany({
    ...(await entryPageQuery(
      prisma,
      { courseId, status: 'submitted', deletedAt: null },
      cursor,
      limit
    )),
    include: { artifacts: true, _count: { select: { captureMarkers: true } } },
  });
  return cursorPage(entries, limit);
}

async function entryPageQuery(
  prisma: PrismaClient,
  visibleWhere: Prisma.PracticeEntryWhereInput,
  cursor: string | undefined,
  limit: number
) {
  const cursorFilter = await buildCursorFilter(prisma, visibleWhere, cursor);
  return {
    where: { ...visibleWhere, ...(cursorFilter ? { OR: cursorFilter } : {}) },
    orderBy: [
      { practiceDate: 'desc' },
      { createdAt: 'desc' },
      { id: 'desc' },
    ] satisfies Prisma.PracticeEntryOrderByWithRelationInput[],
    take: limit + 1,
  };
}

async function buildCursorFilter(
  prisma: PrismaClient,
  visibleWhere: Prisma.PracticeEntryWhereInput,
  cursor: string | undefined
): Promise<Prisma.PracticeEntryWhereInput['OR'] | undefined> {
  if (!cursor) return undefined;
  const entry = await prisma.practiceEntry.findFirst({
    where: { ...visibleWhere, id: cursor },
    select: { practiceDate: true, createdAt: true, id: true },
  });
  if (!entry) throw new ApiError(400, ErrorCodes.VALIDATION_ERROR, 'Invalid cursor');
  return [
    { practiceDate: { lt: entry.practiceDate } },
    { practiceDate: entry.practiceDate, createdAt: { lt: entry.createdAt } },
    { practiceDate: entry.practiceDate, createdAt: entry.createdAt, id: { lt: entry.id } },
  ];
}
