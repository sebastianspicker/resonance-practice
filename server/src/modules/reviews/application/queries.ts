/** Review read-model queries for versioned review adapters. */
import type { PrismaClient } from '@prisma/client';
import { cursorPage } from '../../../platform/http/pagination.js';
import { ApiError } from '../../../platform/http/errors.js';
import { ErrorCodes } from '../../../platform/http/errorCodes.js';

export async function readEntryFeedback(
  prisma: PrismaClient,
  entryId: string,
  cursor: string | undefined,
  limit: number
) {
  const anchor = cursor
    ? await prisma.feedback.findFirst({
        where: { id: cursor, entryId },
        select: { id: true, createdAt: true },
      })
    : null;
  if (cursor && !anchor) throw new ApiError(400, ErrorCodes.VALIDATION_ERROR, 'Invalid cursor');
  const rows = await prisma.feedback.findMany({
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
    take: limit + 1,
  });
  return cursorPage(rows, limit);
}
