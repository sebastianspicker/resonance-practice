/** Versioned mobile-sync API: ordered commands and artifact-session handoff. */
import type { S3Client } from '@aws-sdk/client-s3';
import { GetObjectCommand } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import type { Prisma, PrismaClient } from '@prisma/client';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { config, limits } from '../config.js';
import { ErrorCodes } from '../errorCodes.js';
import { ApiError } from '../errors.js';
import { completeArtifactSession, createArtifactSession } from '../services/artifactSessions.js';
import { withDeadline } from '../services/deadline.js';
import { createSyncAdmission } from '../services/sync/admission.js';
import {
  executeSyncCommand,
  parseSyncCommand,
  type SyncCommandResult,
} from '../services/syncCommands.js';
import {
  requireClientId,
  requireCourseRole,
  requireEnum,
  requireNumber,
  requireRecord,
  requireVisibleCourseEntry,
} from '../validation.js';
import { serializeFeedback } from './feedbackSerialization.js';
import { readEntryFeedback } from './entries.js';

const ENTRY_STATUSES = ['draft', 'submitted', 'reviewed'] as const;
const ENTRY_PAGE_SIZE = 50;
const ENTRY_PAGE_MAX = 200;
const DOWNLOAD_TTL_SECONDS = 900;

/** Register the ordered sync, immutable upload, and authenticated read APIs. */
export function registerV1Routes(
  app: FastifyInstance,
  prisma: PrismaClient,
  s3: S3Client,
  requireAuth: (request: FastifyRequest) => Promise<void>
) {
  registerSyncRoutes(app, prisma, requireAuth);
  registerArtifactSessionRoutes(app, prisma, s3, requireAuth);
  registerReadRoutes(app, prisma, s3, requireAuth);
}

/** Admit bounded batches and execute them serially in client-supplied order. */
function registerSyncRoutes(
  app: FastifyInstance,
  prisma: PrismaClient,
  requireAuth: (request: FastifyRequest) => Promise<void>
) {
  const admission = createSyncAdmission();
  app.post('/api/v1/sync/commands', { preHandler: requireAuth }, async (request) => {
    admission.admitRequest(request.user!.id);
    const body = requireRecord(request.body, 'body');
    if (!Array.isArray(body.commands) || body.commands.length === 0 || body.commands.length > 25) {
      throw new ApiError(
        400,
        ErrorCodes.VALIDATION_ERROR,
        'commands must contain between 1 and 25 commands'
      );
    }
    admission.admitCommands(request.user!.id, body.commands.length);
    const commands = body.commands.map(parseSyncCommand);
    const results: SyncCommandResult[] = [];
    // Preserve client FIFO so dependent commands observe the versions and
    // resources returned by every earlier command in the same request.
    for (const command of commands) {
      results.push(await executeSyncCommand(prisma, request.user!.id, command));
    }
    return { results };
  });
}

/** Expose the only supported artifact mutation lifecycle: allocate, upload, complete. */
function registerArtifactSessionRoutes(
  app: FastifyInstance,
  prisma: PrismaClient,
  s3: S3Client,
  requireAuth: (request: FastifyRequest) => Promise<void>
) {
  app.post('/api/v1/artifact-sessions', { preHandler: requireAuth }, async (request) => {
    const body = requireRecord(request.body, 'body');
    return createArtifactSession(prisma, s3, {
      userId: request.user!.id,
      operationId: requireClientId(body.operationId, 'operationId'),
      entryId: requireClientId(body.entryId, 'entryId'),
      artifactId: requireClientId(body.artifactId, 'artifactId'),
      type: requireEnum(body.type, 'type', ['audio', 'video'] as const),
      durationSeconds: requireNumber(body.durationSeconds, 'durationSeconds', {
        integer: true,
        min: 0,
        max: limits.maxDurationSeconds,
      }),
      sizeBytes: requireNumber(body.sizeBytes, 'sizeBytes', {
        integer: true,
        min: 1,
        max: limits.maxUploadSizeBytes,
      }),
      baseVersion: requireNumber(body.baseVersion, 'baseVersion', {
        integer: true,
        min: 1,
      }),
    });
  });

  app.post(
    '/api/v1/artifact-sessions/:sessionId/complete',
    { preHandler: requireAuth },
    async (request) =>
      completeArtifactSession(
        prisma,
        s3,
        request.user!.id,
        requireClientId((request.params as { sessionId: string }).sessionId, 'sessionId')
      )
  );
}

/** Expose role-filtered projections without weakening the legacy authorization rules. */
function registerReadRoutes(
  app: FastifyInstance,
  prisma: PrismaClient,
  s3: S3Client,
  requireAuth: (request: FastifyRequest) => Promise<void>
) {
  app.get('/api/v1/me', { preHandler: requireAuth }, async (request) => {
    const user = await prisma.user.findUnique({
      where: { id: request.user!.id },
      select: { id: true, displayName: true, globalRole: true },
    });
    if (!user) throw new ApiError(404, ErrorCodes.NOT_FOUND, 'User not found');
    return user;
  });

  app.get('/api/v1/courses', { preHandler: requireAuth }, async (request) => {
    const memberships = await prisma.membership.findMany({
      where: { userId: request.user!.id },
      include: { course: true },
      orderBy: { courseId: 'asc' },
    });
    return memberships.map((membership) => ({
      id: membership.course.id,
      title: membership.course.title,
      roleInCourse: membership.roleInCourse,
    }));
  });

  app.get('/api/v1/courses/:courseId/entries', { preHandler: requireAuth }, async (request) => {
    const courseId = requireClientId((request.params as { courseId: string }).courseId, 'courseId');
    const role = await requireCourseRole(prisma, request.user!.id, courseId);
    const query = request.query as { status?: string; cursor?: string; limit?: string };
    const status =
      query.status === undefined ? undefined : requireEnum(query.status, 'status', ENTRY_STATUSES);
    if (role === 'teacher' && status === 'draft') {
      throw new ApiError(
        403,
        ErrorCodes.ENTRY_ACCESS_DENIED,
        'Draft entries are not visible to teachers'
      );
    }
    const where: Prisma.PracticeEntryWhereInput = {
      courseId,
      deletedAt: null,
      ...(role === 'student'
        ? { studentId: request.user!.id, ...(status ? { status } : {}) }
        : { status: status ?? 'submitted' }),
    };
    return readEntryPage(prisma, where, query.cursor, parsePageLimit(query.limit));
  });

  app.get(
    '/api/v1/courses/:courseId/review-queue',
    { preHandler: requireAuth },
    async (request) => {
      const courseId = requireClientId(
        (request.params as { courseId: string }).courseId,
        'courseId'
      );
      const role = await requireCourseRole(prisma, request.user!.id, courseId);
      if (role !== 'teacher') {
        throw new ApiError(
          403,
          ErrorCodes.TEACHER_ONLY,
          'Only teachers can access the review queue'
        );
      }
      const query = request.query as { cursor?: string; limit?: string };
      const page = await readEntryPage(
        prisma,
        { courseId, status: 'submitted', deletedAt: null },
        query.cursor,
        parsePageLimit(query.limit)
      );
      const userIds = [...new Set(page.items.map((entry) => entry.studentId))];
      const students = await prisma.user.findMany({
        where: { id: { in: userIds } },
        select: { id: true, displayName: true },
      });
      const names = new Map(students.map((student) => [student.id, student.displayName]));
      return {
        ...page,
        items: page.items.map((entry) => ({
          ...entry,
          studentName: names.get(entry.studentId) ?? '',
          captureMarkerCount: entry.captureMarkers.length,
        })),
      };
    }
  );

  app.get('/api/v1/entries/:entryId', { preHandler: requireAuth }, async (request) => {
    const entryId = requireClientId((request.params as { entryId: string }).entryId, 'entryId');
    return readAccessibleEntry(prisma, request.user!.id, entryId);
  });

  app.get('/api/v1/entries/:entryId/feedback', { preHandler: requireAuth }, async (request) => {
    const entry = await readAccessibleEntry(
      prisma,
      request.user!.id,
      requireClientId((request.params as { entryId: string }).entryId, 'entryId')
    );
    const feedback = await readEntryFeedback(prisma, entry.id);
    return serializeFeedback(feedback);
  });

  app.post(
    '/api/v1/artifacts/:artifactId/download-session',
    { preHandler: requireAuth },
    async (request, reply) => {
      const artifactId = requireClientId(
        (request.params as { artifactId: string }).artifactId,
        'artifactId'
      );
      const artifact = await prisma.artifact.findUnique({
        where: { id: artifactId },
        include: { entry: true },
      });
      if (!artifact || artifact.uploadState !== 'uploaded' || !artifact.storageKey) {
        throw new ApiError(404, ErrorCodes.ARTIFACT_NOT_FOUND, 'Artifact not found');
      }
      await requireVisibleCourseEntry(prisma, request.user!.id, artifact.entry);
      const downloadUrl = await withDeadline(
        () =>
          getSignedUrl(
            s3,
            new GetObjectCommand({
              Bucket: config.s3.bucket,
              Key: artifact.storageKey!,
            }),
            { expiresIn: DOWNLOAD_TTL_SECONDS }
          ),
        config.dependencyTimeoutMs,
        'S3 download presign'
      );
      reply.header('Cache-Control', 'no-store');
      return { downloadUrl, expiresInSeconds: DOWNLOAD_TTL_SECONDS };
    }
  );
}

async function readEntryPage(
  prisma: PrismaClient,
  visibleWhere: Prisma.PracticeEntryWhereInput,
  cursor: string | undefined,
  limit: number
) {
  const where = { ...visibleWhere };
  const cursorFilter = await buildCursorFilter(prisma, visibleWhere, cursor);
  if (cursorFilter) where.OR = cursorFilter;
  const entries = await prisma.practiceEntry.findMany({
    where,
    include: {
      artifacts: true,
      captureMarkers: true,
    },
    orderBy: [{ practiceDate: 'desc' }, { createdAt: 'desc' }, { id: 'desc' }],
    take: limit + 1,
  });
  const hasMore = entries.length > limit;
  const items = hasMore ? entries.slice(0, limit) : entries;
  return {
    items,
    nextCursor: hasMore ? (items.at(-1)?.id ?? null) : null,
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
  if (!entry) {
    throw new ApiError(400, ErrorCodes.VALIDATION_ERROR, 'Invalid cursor');
  }
  return [
    { practiceDate: { lt: entry.practiceDate } },
    { practiceDate: entry.practiceDate, createdAt: { lt: entry.createdAt } },
    {
      practiceDate: entry.practiceDate,
      createdAt: entry.createdAt,
      id: { lt: entry.id },
    },
  ];
}

/** Load an entry and apply the same owner/course visibility rule used by other reads. */
async function readAccessibleEntry(prisma: PrismaClient, userId: string, entryId: string) {
  const entry = await prisma.practiceEntry.findUnique({
    where: { id: entryId },
    include: {
      artifacts: true,
      captureMarkers: true,
    },
  });
  if (!entry) throw new ApiError(404, ErrorCodes.ENTRY_NOT_FOUND, 'Entry not found');
  await requireVisibleCourseEntry(prisma, userId, entry);
  return entry;
}

function parsePageLimit(raw: string | undefined): number {
  if (raw === undefined) return ENTRY_PAGE_SIZE;
  return Math.min(requireNumber(Number(raw), 'limit', { integer: true, min: 1 }), ENTRY_PAGE_MAX);
}
