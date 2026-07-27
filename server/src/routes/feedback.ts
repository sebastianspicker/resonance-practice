/** Feedback HTTP routes and their locked-entry authorization workflow. */
import type { PracticeEntry, PrismaClient } from '@prisma/client';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { nanoid } from 'nanoid';
import { limits } from '../config.js';
import { ErrorCodes } from '../errorCodes.js';
import { ApiError, withPrismaErrors } from '../errors.js';
import { type EntryTransaction, withLockedEntry } from '../services/entryTransaction.js';
import {
  requireCourseRole,
  requireClientId,
  requireEnum,
  requireField,
  requireNumber,
  requireRecord,
  requireString,
} from '../validation.js';

export function registerFeedbackRoutes(
  app: FastifyInstance,
  prisma: PrismaClient,
  requireAuth: (request: FastifyRequest) => Promise<void>
) {
  app.post('/feedback', { preHandler: requireAuth }, async (request, reply) => {
    const user = request.user!;
    const parsed = parseFeedbackRequest(requireRecord(request.body, 'body'));
    const target = await resolveFeedbackTarget(prisma, parsed.targetType, parsed.targetId);

    // Feedback is course-scoped. A global teacher role is not enough; the user
    // must be a teacher on the target entry's course.
    const roleInCourse = await requireCourseRole(prisma, user.id, target.courseId);
    if (roleInCourse !== 'teacher') {
      throw new ApiError(403, ErrorCodes.TEACHER_ONLY, 'Only course teachers can leave feedback');
    }

    const feedbackId = parsed.requestedFeedbackId ?? `fb_${nanoid(12)}`;
    const markerCreates = makeMarkerCreates(parsed.markers);

    const result = await withPrismaErrors(
      () =>
        withLockedEntry(prisma, target.reviewEntryId, (tx, lockedEntry) =>
          processLockedFeedback(tx, lockedEntry, {
            userId: user.id,
            requestedFeedbackId: parsed.requestedFeedbackId,
            feedbackId,
            targetType: parsed.targetType,
            targetId: parsed.targetId,
            reviewEntryId: target.reviewEntryId,
            status: parsed.status,
            commentsText: parsed.commentsText,
            markers: parsed.markers,
            markerCreates,
          })
        ),
      {
        notFoundCode: ErrorCodes.ENTRY_NOT_FOUND,
        notFoundMessage: 'Entry was deleted during feedback creation',
      }
    );
    return reply.status(result.created ? 201 : 200).send({
      ...result.feedback,
      teacherName: result.feedback.teacher.displayName,
    });
  });
}

type ParsedFeedbackRequest = {
  requestedFeedbackId: string | undefined;
  targetType: 'entry' | 'artifact';
  targetId: string;
  status: 'ok' | 'needs_revision' | 'next_goal';
  commentsText: string;
  markers: Array<{ timeSeconds: number; text: string }>;
};

function parseFeedbackRequest(body: Record<string, unknown>): ParsedFeedbackRequest {
  const requestedFeedbackId = body.id === undefined ? undefined : requireClientId(body.id, 'id');
  const targetType = requireEnum(requireField(body.targetType, 'targetType'), 'targetType', [
    'entry',
    'artifact',
  ] as const);
  const targetId = requireString(requireField(body.targetId, 'targetId'), 'targetId');
  const status = requireEnum(requireField(body.status, 'status'), 'status', [
    'ok',
    'needs_revision',
    'next_goal',
  ] as const);
  const commentsText = requireString(
    requireField(body.commentsText, 'commentsText'),
    'commentsText',
    { minLength: 1, max: limits.maxCommentsTextLength }
  );
  const rawMarkers = Object.prototype.hasOwnProperty.call(body, 'markers')
    ? requireMarkerArray(body.markers)
    : [];
  return {
    requestedFeedbackId,
    targetType,
    targetId,
    status,
    commentsText,
    markers: parseFeedbackMarkers(rawMarkers),
  };
}

function parseFeedbackMarkers(
  rawMarkers: Record<string, unknown>[]
): Array<{ timeSeconds: number; text: string }> {
  if (rawMarkers.length > limits.maxMarkers) {
    throw new ApiError(
      400,
      ErrorCodes.VALIDATION_ERROR,
      `Too many markers (max ${limits.maxMarkers})`
    );
  }
  return rawMarkers.map((marker) => ({
    timeSeconds: requireNumber(marker.timeSeconds, 'marker.timeSeconds', {
      integer: true,
      min: 0,
      max: limits.maxMarkerTimeSeconds,
    }),
    text: requireString(requireField(marker.text, 'marker.text'), 'marker.text', {
      max: limits.maxMarkerTextLength,
    }),
  }));
}

function makeMarkerCreates(markers: Array<{ timeSeconds: number; text: string }>) {
  return markers.map((marker) => ({
    id: `mk_${nanoid(10)}`,
    timeSeconds: marker.timeSeconds,
    text: marker.text,
  }));
}

async function resolveFeedbackTarget(
  prisma: PrismaClient,
  targetType: ParsedFeedbackRequest['targetType'],
  targetId: string
): Promise<{ courseId: string; reviewEntryId: string }> {
  if (targetType === 'entry') {
    const entry = await prisma.practiceEntry.findUnique({ where: { id: targetId } });
    if (!entry) throw new ApiError(404, ErrorCodes.ENTRY_NOT_FOUND, 'Entry not found');
    requireSubmittedEntry(entry);
    return { courseId: entry.courseId, reviewEntryId: entry.id };
  }

  const artifact = await prisma.artifact.findUnique({
    where: { id: targetId },
    include: { entry: true },
  });
  if (!artifact) throw new ApiError(404, ErrorCodes.ARTIFACT_NOT_FOUND, 'Artifact not found');
  requireSubmittedEntry(artifact.entry);
  return { courseId: artifact.entry.courseId, reviewEntryId: artifact.entry.id };
}

function requireSubmittedEntry(entry: Pick<PracticeEntry, 'deletedAt' | 'status'>): void {
  if (entry.deletedAt) {
    throw new ApiError(410, ErrorCodes.ENTRY_DELETED, 'Entry has been deleted');
  }
  if (entry.status === 'draft') {
    throw new ApiError(
      409,
      ErrorCodes.ENTRY_NOT_SUBMITTED,
      'Entry must be submitted before feedback can be added'
    );
  }
}

type FeedbackInput = {
  userId: string;
  requestedFeedbackId: string | undefined;
  feedbackId: string;
  targetType: 'entry' | 'artifact';
  targetId: string;
  reviewEntryId: string;
  status: 'ok' | 'needs_revision' | 'next_goal';
  commentsText: string;
  markers: Array<{ timeSeconds: number; text: string }>;
  markerCreates: Array<{ id: string; timeSeconds: number; text: string }>;
};

async function processLockedFeedback(
  tx: EntryTransaction,
  lockedEntry: PracticeEntry,
  input: FeedbackInput
) {
  requireActiveLockedEntry(lockedEntry);
  await requireLockedFeedbackTarget(tx, lockedEntry, input.targetType, input.targetId);

  const existingFeedback = await findExistingFeedback(tx, input.requestedFeedbackId);
  if (existingFeedback) {
    requireMatchingFeedback(existingFeedback, input);
    if (lockedEntry.status !== 'reviewed') {
      await markEntryReviewed(tx, input.reviewEntryId);
    }
    return { feedback: existingFeedback, created: false };
  }

  const feedback = await tx.feedback.create({
    data: {
      id: input.feedbackId,
      targetType: input.targetType,
      targetId: input.targetId,
      teacherId: input.userId,
      entryId: input.reviewEntryId,
      status: input.status,
      commentsText: input.commentsText,
      markers: { create: input.markerCreates },
    },
    include: { markers: true, teacher: true },
  });

  // Product rule: any teacher feedback, whether on the entry or one of its
  // artifacts, marks the parent entry as reviewed.
  await markEntryReviewed(tx, input.reviewEntryId);
  return { feedback, created: true };
}

function requireActiveLockedEntry(lockedEntry: PracticeEntry): void {
  if (lockedEntry.deletedAt) {
    throw new ApiError(410, ErrorCodes.ENTRY_DELETED, 'Entry has been deleted');
  }
  if (lockedEntry.status === 'draft') {
    throw new ApiError(
      409,
      ErrorCodes.ENTRY_NOT_SUBMITTED,
      'Entry must be submitted before feedback can be added'
    );
  }
}

async function requireLockedFeedbackTarget(
  tx: EntryTransaction,
  lockedEntry: PracticeEntry,
  targetType: FeedbackInput['targetType'],
  targetId: string
): Promise<void> {
  // The target may have changed while authorization was evaluated. Re-resolve
  // it under the same parent-entry lock used by related entry mutations.
  if (targetType === 'entry') {
    if (targetId !== lockedEntry.id) {
      throw new ApiError(404, ErrorCodes.ENTRY_NOT_FOUND, 'Entry not found');
    }
    return;
  }

  const lockedArtifact = await tx.artifact.findUnique({ where: { id: targetId } });
  if (!lockedArtifact || lockedArtifact.entryId !== lockedEntry.id) {
    throw new ApiError(404, ErrorCodes.ARTIFACT_NOT_FOUND, 'Artifact not found');
  }
}

function findExistingFeedback(tx: EntryTransaction, requestedFeedbackId: string | undefined) {
  return requestedFeedbackId
    ? tx.feedback.findUnique({
        where: { id: requestedFeedbackId },
        include: { markers: true, teacher: true },
      })
    : null;
}

function requireMatchingFeedback(
  existingFeedback: {
    teacherId: string;
    targetType: string;
    targetId: string;
    entryId: string | null;
    status: string;
    commentsText: string;
    markers: Array<{ timeSeconds: number; text: string }>;
  },
  input: FeedbackInput
): void {
  if (
    existingFeedback.teacherId !== input.userId ||
    existingFeedback.targetType !== input.targetType ||
    existingFeedback.targetId !== input.targetId ||
    existingFeedback.entryId !== input.reviewEntryId ||
    !feedbackBodyMatches(existingFeedback, input)
  ) {
    throw new ApiError(409, ErrorCodes.ID_CONFLICT, 'Feedback ID already exists');
  }
}

async function markEntryReviewed(tx: EntryTransaction, reviewEntryId: string): Promise<void> {
  await tx.practiceEntry.update({
    where: { id: reviewEntryId },
    data: { status: 'reviewed', version: { increment: 1 } },
  });
}

function requireMarkerArray(value: unknown): Record<string, unknown>[] {
  if (!Array.isArray(value)) {
    throw new ApiError(400, ErrorCodes.VALIDATION_ERROR, 'Invalid array: markers');
  }
  return value as Record<string, unknown>[];
}

function feedbackBodyMatches(
  existingFeedback: {
    status: string;
    commentsText: string;
    markers: Array<{ timeSeconds: number; text: string }>;
  },
  requested: {
    status: string;
    commentsText: string;
    markers: Array<{ timeSeconds: number; text: string }>;
  }
): boolean {
  if (
    existingFeedback.status !== requested.status ||
    existingFeedback.commentsText !== requested.commentsText
  ) {
    return false;
  }

  return markerSetsMatch(existingFeedback.markers, requested.markers);
}

function markerSetsMatch(
  existingMarkers: Array<{ timeSeconds: number; text: string }>,
  requestedMarkers: Array<{ timeSeconds: number; text: string }>
): boolean {
  if (existingMarkers.length !== requestedMarkers.length) {
    return false;
  }
  if (existingMarkers.length > limits.maxMarkers) {
    return false;
  }

  const existing = normalizeMarkers(existingMarkers);
  const requested = normalizeMarkers(requestedMarkers);
  return existing.every(
    (marker, index) =>
      marker.timeSeconds === requested[index]?.timeSeconds && marker.text === requested[index]?.text
  );
}

function normalizeMarkers(markers: Array<{ timeSeconds: number; text: string }>) {
  const normalized: Array<{ timeSeconds: number; text: string }> = [];
  for (let index = 0; index < limits.maxMarkers; index += 1) {
    if (index >= markers.length) break;
    const marker = markers[index]!;
    normalized.push({ timeSeconds: marker.timeSeconds, text: marker.text });
  }
  return normalized.sort((a, b) => a.timeSeconds - b.timeSeconds || a.text.localeCompare(b.text));
}
