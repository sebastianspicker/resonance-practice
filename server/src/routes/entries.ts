import type { S3Client } from '@aws-sdk/client-s3';
import type { PrismaClient } from '@prisma/client';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { limits } from '../config.js';
import { ErrorCodes } from '../errorCodes.js';
import { ApiError, withPrismaErrors } from '../errors.js';
import { cascadeDeleteEntry, cleanupS3Objects } from '../services/entryCascade.js';
import {
  requireClientId,
  requireCourseRole,
  requireEntryAccess,
  requireField,
  requireNumber,
  requireString,
  requireStringArray,
  requireStudentOwner,
  requireValidDate,
} from '../validation.js';

export function registerEntryRoutes(
  app: FastifyInstance,
  prisma: PrismaClient,
  s3: S3Client,
  requireAuth: (request: FastifyRequest) => Promise<void>
) {
  app.post('/courses/:courseId/entries', { preHandler: requireAuth }, async (request, reply) => {
    const user = request.user!;
    const courseId = (request.params as { courseId: string }).courseId;
    const role = await requireCourseRole(prisma, user.id, courseId);
    if (role !== 'student') {
      throw new ApiError(403, ErrorCodes.STUDENT_ONLY, 'Only students can create entries');
    }
    const body = request.body as Record<string, unknown>;
    const entryId = requireClientId(requireField(body?.id, 'id'), 'id');
    const practiceDate = requireValidDate(body?.practiceDate, 'practiceDate');
    const goalText = requireString(requireField(body?.goalText, 'goalText'), 'goalText', {
      minLength: 1,
    });
    const tags =
      body?.tags === undefined
        ? []
        : requireStringArray(body.tags, 'tags', { max: limits.maxTags });
    for (const tag of tags) {
      requireString(tag, 'tags[]', { max: limits.maxTagLength });
    }
    const durationSeconds =
      body?.durationSeconds === undefined
        ? null
        : requireNumber(body?.durationSeconds, 'durationSeconds', {
            integer: true,
            min: 0,
            max: limits.maxDurationSeconds,
          });
    const notes =
      body?.notes === undefined || body?.notes === null ? null : requireString(body.notes, 'notes');
    const created = await withPrismaErrors(
      () =>
        prisma.practiceEntry.create({
          data: {
            id: entryId,
            courseId,
            studentId: user.id,
            practiceDate,
            goalText,
            durationSeconds,
            tags,
            notes,
            status: 'draft',
          },
        }),
      { conflictMessage: 'An entry with this ID already exists' }
    );
    return reply.status(201).send(created);
  });

  app.get('/entries/:entryId', { preHandler: requireAuth }, async (request) => {
    const user = request.user!;
    const entryId = (request.params as { entryId: string }).entryId;
    const entry = await requireEntryAccess(prisma, user, entryId);
    const artifacts = await prisma.artifact.findMany({
      where: { entryId: entry.id },
      orderBy: [{ createdAt: 'asc' }, { id: 'asc' }],
    });
    return { ...entry, artifacts };
  });

  app.patch('/entries/:entryId', { preHandler: requireAuth }, async (request) => {
    const user = request.user!;
    const entryId = (request.params as { entryId: string }).entryId;
    const entry = await requireEntryAccess(prisma, user, entryId);
    await requireStudentOwner(prisma, user.id, entry, 'edit entries', entry.roleInCourse);

    const body = request.body as Record<string, unknown>;

    // Check submitted-entry lock using "field present in body" instead of truthiness
    // This prevents bypassing the lock with falsy values like "" or 0
    if (entry.status !== 'draft') {
      const hasRestrictedField =
        'goalText' in body ||
        'practiceDate' in body ||
        'tags' in body ||
        'durationSeconds' in body ||
        'notes' in body;
      if (hasRestrictedField) {
        throw new ApiError(409, ErrorCodes.ENTRY_LOCKED, 'Only draft entries can be edited');
      }
    }

    // Build update data with proper null handling
    const updateData: Record<string, unknown> = {};

    if ('goalText' in body) {
      updateData.goalText = requireString(body.goalText, 'goalText', { minLength: 1 });
    }

    if ('practiceDate' in body) {
      updateData.practiceDate = requireValidDate(body.practiceDate, 'practiceDate');
    }

    if ('durationSeconds' in body) {
      // Allow explicit null to clear the field
      if (body.durationSeconds === null) {
        updateData.durationSeconds = null;
      } else {
        updateData.durationSeconds = requireNumber(body.durationSeconds, 'durationSeconds', {
          integer: true,
          min: 0,
          max: limits.maxDurationSeconds,
        });
      }
    }

    if ('tags' in body) {
      const tags = requireStringArray(body.tags, 'tags', { max: limits.maxTags });
      for (const tag of tags) {
        requireString(tag, 'tags[]', { max: limits.maxTagLength });
      }
      updateData.tags = tags;
    }

    if ('notes' in body) {
      // Allow explicit null to clear the field
      updateData.notes = body.notes === null ? null : requireString(body.notes, 'notes');
    }

    const updated = await withPrismaErrors(
      () =>
        prisma.practiceEntry.update({
          where: { id: entryId },
          data: updateData,
        }),
      {
        notFoundCode: ErrorCodes.ENTRY_NOT_FOUND,
        notFoundMessage: 'Entry not found',
      }
    );
    return updated;
  });

  app.delete('/entries/:entryId', { preHandler: requireAuth }, async (request, reply) => {
    const user = request.user!;
    const entryId = (request.params as { entryId: string }).entryId;
    const entry = await requireEntryAccess(prisma, user, entryId);
    await requireStudentOwner(prisma, user.id, entry, 'delete', entry.roleInCourse);

    const storageKeys = await cascadeDeleteEntry(prisma, entryId);
    await cleanupS3Objects(s3, storageKeys, request.log);

    reply.status(204).send();
  });

  app.post('/entries/:entryId/submit', { preHandler: requireAuth }, async (request) => {
    const user = request.user!;
    const entryId = (request.params as { entryId: string }).entryId;
    const entry = await requireEntryAccess(prisma, user, entryId);
    await requireStudentOwner(prisma, user.id, entry, 'submit', entry.roleInCourse);
    if (entry.status !== 'draft') {
      throw new ApiError(409, ErrorCodes.ENTRY_LOCKED, 'Only draft entries can be submitted');
    }
    const artifacts = await prisma.artifact.findMany({ where: { entryId } });
    if (artifacts.length === 0 || artifacts.some((a) => a.uploadState !== 'uploaded')) {
      throw new ApiError(
        409,
        ErrorCodes.ARTIFACTS_NOT_UPLOADED,
        'Upload artifacts before submitting'
      );
    }
    const updated = await withPrismaErrors(
      () =>
        prisma.practiceEntry.update({
          where: { id: entryId },
          data: { status: 'submitted' },
        }),
      {
        notFoundCode: ErrorCodes.ENTRY_NOT_FOUND,
        notFoundMessage: 'Entry not found',
      }
    );
    return updated;
  });

  app.get('/entries/:entryId/feedback', { preHandler: requireAuth }, async (request) => {
    const user = request.user!;
    const entryId = (request.params as { entryId: string }).entryId;
    const entry = await requireEntryAccess(prisma, user, entryId);
    const feedback = await prisma.feedback.findMany({
      where: { entryId: entry.id },
      include: {
        markers: true,
        teacher: { select: { displayName: true } },
      },
      orderBy: [{ createdAt: 'asc' }, { id: 'asc' }],
    });
    return feedback.map((item) => ({
      id: item.id,
      targetType: item.targetType,
      targetId: item.targetId,
      teacherId: item.teacherId,
      teacherName: item.teacher.displayName,
      createdAt: item.createdAt,
      status: item.status,
      commentsText: item.commentsText,
      markers: item.markers,
    }));
  });
}
