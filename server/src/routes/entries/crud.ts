import type { PrismaClient } from '@prisma/client';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { ErrorCodes } from '../../errorCodes.js';
import { ApiError, isPrismaError, withPrismaErrors } from '../../errors.js';
import { lockEntryIdentity, withLockedEntry } from '../../services/entryTransaction.js';
import {
  hasRestrictedEntryPatchField,
  isExactEntryCreateRetry,
  parseEntryCreateBody,
  parseEntryPatchBody,
  requireActiveEntry,
} from './parsing.js';
import {
  requireCourseRole,
  requireEntryAccess,
  requireRecord,
  requireStudentOwner,
} from '../../validation.js';

export function registerEntryCrudRoutes(
  app: FastifyInstance,
  prisma: PrismaClient,
  requireAuth: (request: FastifyRequest) => Promise<void>
) {
  app.post('/courses/:courseId/entries', { preHandler: requireAuth }, async (request, reply) => {
    const user = request.user!;
    const courseId = (request.params as { courseId: string }).courseId;
    const role = await requireCourseRole(prisma, user.id, courseId);
    if (role !== 'student') {
      throw new ApiError(403, ErrorCodes.STUDENT_ONLY, 'Only students can create entries');
    }
    const body = requireRecord(request.body, 'body');
    const entryData = parseEntryCreateBody(body);
    try {
      const result = await prisma.$transaction(async (tx) => {
        await lockEntryIdentity(tx, entryData.id);
        const tombstone = await tx.deletedEntryTombstone.findUnique({
          where: { id: entryData.id },
        });
        if (tombstone) {
          throw new ApiError(410, ErrorCodes.ENTRY_DELETED, 'Entry ID has been deleted');
        }

        const existing = await tx.practiceEntry.findUnique({ where: { id: entryData.id } });
        if (existing) {
          if (isExactEntryCreateRetry(existing, entryData, courseId, user.id)) {
            return { entry: existing, created: false };
          }
          throw new ApiError(409, ErrorCodes.ID_CONFLICT, 'An entry with this ID already exists');
        }

        const created = await tx.practiceEntry.create({
          data: {
            id: entryData.id,
            courseId,
            studentId: user.id,
            kind: entryData.kind,
            practiceDate: entryData.practiceDate,
            goalText: entryData.goalText,
            durationSeconds: entryData.durationSeconds,
            tags: entryData.tags,
            notes: entryData.notes,
            status: 'draft',
            consentConfirmedAt: entryData.consentConfirmedAt,
            consentScope: entryData.consentScope,
            captureProfile: entryData.captureProfile,
          },
        });
        return { entry: created, created: true };
      });
      return reply.status(result.created ? 201 : 200).send(result.entry);
    } catch (error) {
      if (isPrismaError(error, 'P2002')) {
        throw new ApiError(409, ErrorCodes.ID_CONFLICT, 'An entry with this ID already exists');
      }
      throw error;
    }
  });

  app.get('/entries/:entryId', { preHandler: requireAuth }, async (request) => {
    const user = request.user!;
    const entryId = (request.params as { entryId: string }).entryId;
    const entry = await requireEntryAccess(prisma, user, entryId);
    const artifacts = await prisma.artifact.findMany({
      where: { entryId: entry.id },
      orderBy: [{ createdAt: 'asc' }, { id: 'asc' }],
    });
    const captureMarkers = await prisma.captureMarker.findMany({
      where: { entryId: entry.id },
      orderBy: [{ timeSeconds: 'asc' }, { createdAt: 'asc' }, { id: 'asc' }],
    });
    return { ...entry, artifacts, captureMarkers };
  });

  app.patch('/entries/:entryId', { preHandler: requireAuth }, async (request) => {
    const user = request.user!;
    const entryId = (request.params as { entryId: string }).entryId;
    const entry = await requireEntryAccess(prisma, user, entryId);
    await requireStudentOwner(prisma, user.id, entry, 'edit entries', entry.roleInCourse);

    const body = requireRecord(request.body, 'body');

    return withLockedEntry(prisma, entryId, async (tx, lockedEntry) => {
      requireActiveEntry(lockedEntry);
      if (lockedEntry.status !== 'draft' && hasRestrictedEntryPatchField(body)) {
        throw new ApiError(409, ErrorCodes.ENTRY_LOCKED, 'Only draft entries can be edited');
      }

      const updateData = parseEntryPatchBody(body, lockedEntry);
      return withPrismaErrors(
        () =>
          tx.practiceEntry.update({
            where: { id: entryId },
            data: { ...updateData, version: { increment: 1 } },
          }),
        {
          notFoundCode: ErrorCodes.ENTRY_NOT_FOUND,
          notFoundMessage: 'Entry not found',
        }
      );
    });
  });
}
