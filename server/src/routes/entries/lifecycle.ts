import type { PrismaClient } from '@prisma/client';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { ErrorCodes } from '../../errorCodes.js';
import { ApiError } from '../../errors.js';
import { cascadeDeleteEntry } from '../../services/entryCascade.js';
import { withLockedEntry } from '../../services/entryTransaction.js';
import { requireActiveEntry } from './parsing.js';
import { serializeFeedback } from '../feedbackSerialization.js';
import { requireEntryAccess, requireStudentOwner } from '../../validation.js';

export async function readEntryFeedback(prisma: PrismaClient, entryId: string) {
  return prisma.feedback.findMany({
    where: { entryId },
    include: {
      markers: true,
      teacher: { select: { displayName: true } },
    },
    orderBy: [{ createdAt: 'asc' }, { id: 'asc' }],
  });
}

export function registerEntryLifecycleRoutes(
  app: FastifyInstance,
  prisma: PrismaClient,
  requireAuth: (request: FastifyRequest) => Promise<void>
) {
  app.delete('/entries/:entryId', { preHandler: requireAuth }, async (request, reply) => {
    const user = request.user!;
    const entryId = (request.params as { entryId: string }).entryId;
    const entry = await requireEntryAccess(prisma, user, entryId);
    await requireStudentOwner(prisma, user.id, entry, 'delete', entry.roleInCourse);

    await cascadeDeleteEntry(prisma, entryId);

    reply.status(204).send();
  });

  app.post('/entries/:entryId/submit', { preHandler: requireAuth }, async (request) => {
    const user = request.user!;
    const entryId = (request.params as { entryId: string }).entryId;
    const entry = await requireEntryAccess(prisma, user, entryId);
    await requireStudentOwner(prisma, user.id, entry, 'submit', entry.roleInCourse);
    return withLockedEntry(prisma, entryId, async (tx, lockedEntry) => {
      requireActiveEntry(lockedEntry);
      if (lockedEntry.status !== 'draft') {
        throw new ApiError(409, ErrorCodes.ENTRY_LOCKED, 'Only draft entries can be submitted');
      }
      if (
        lockedEntry.kind === 'teaching_lesson' &&
        (lockedEntry.consentConfirmedAt === null || lockedEntry.consentScope === null)
      ) {
        throw new ApiError(
          409,
          ErrorCodes.CONSENT_REQUIRED,
          'Teaching lesson entries require confirmed consent before submission'
        );
      }
      const artifacts = await tx.artifact.findMany({ where: { entryId } });
      if (artifacts.length === 0 || artifacts.some((a) => a.uploadState !== 'uploaded')) {
        throw new ApiError(
          409,
          ErrorCodes.ARTIFACTS_NOT_UPLOADED,
          'Upload artifacts before submitting'
        );
      }
      if (
        lockedEntry.kind === 'teaching_lesson' &&
        !artifacts.some((artifact) => artifact.type === 'video')
      ) {
        throw new ApiError(
          409,
          ErrorCodes.ARTIFACTS_NOT_UPLOADED,
          'Teaching lesson entries require an uploaded video artifact'
        );
      }
      return tx.practiceEntry.update({
        where: { id: entryId },
        data: { status: 'submitted', version: { increment: 1 } },
      });
    });
  });

  app.get('/entries/:entryId/feedback', { preHandler: requireAuth }, async (request) => {
    const user = request.user!;
    const entryId = (request.params as { entryId: string }).entryId;
    const entry = await requireEntryAccess(prisma, user, entryId);
    const feedback = await readEntryFeedback(prisma, entry.id);
    return serializeFeedback(feedback, true);
  });
}
