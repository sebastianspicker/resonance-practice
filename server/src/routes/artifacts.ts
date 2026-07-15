import type { S3Client } from '@aws-sdk/client-s3';
import { GetObjectCommand, HeadObjectCommand, PutObjectCommand } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import type { Artifact, ArtifactType, PrismaClient } from '@prisma/client';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { nanoid } from 'nanoid';
import { config, limits } from '../config.js';
import { ErrorCodes } from '../errorCodes.js';
import { ApiError, withPrismaErrors } from '../errors.js';
import { withLockedEntry } from '../services/entryTransaction.js';
import { withDeadline } from '../services/deadline.js';
import { isS3NotFoundError } from '../storage.js';
import {
  requireClientId,
  requireEnum,
  requireField,
  requireNumber,
  requireRecord,
  requireEntryAccess,
  requireStudentOwner,
} from '../validation.js';

const DOWNLOAD_URL_TTL_SECONDS = 900;

function matchesArtifactCreateIdentity(
  artifact: Artifact,
  entryId: string,
  type: ArtifactType,
  durationSeconds: number
) {
  return [
    artifact.entryId === entryId,
    artifact.type === type,
    artifact.durationSeconds === durationSeconds,
  ].every(Boolean);
}

function isUpgradeablePendingLegacyArtifact(artifact: Artifact) {
  return artifact.expectedSizeBytes === null && artifact.uploadState !== 'uploaded';
}

function isVerifiableUploadedLegacyArtifact(artifact: Artifact) {
  return [
    artifact.expectedSizeBytes === null,
    artifact.uploadState === 'uploaded',
    artifact.storageKey !== null,
  ].every(Boolean);
}

function matchesVerifiedLegacyArtifact(
  artifact: Artifact,
  entryId: string,
  type: ArtifactType,
  durationSeconds: number,
  storageKey: string
) {
  return [
    matchesArtifactCreateIdentity(artifact, entryId, type, durationSeconds),
    artifact.uploadState === 'uploaded',
    artifact.storageKey === storageKey,
  ].every(Boolean);
}

export function registerArtifactRoutes(
  app: FastifyInstance,
  prisma: PrismaClient,
  s3: S3Client,
  requireAuth: (request: FastifyRequest) => Promise<void>
) {
  app.get(
    '/artifacts/:artifactId/download',
    { preHandler: requireAuth },
    async (request, reply) => {
      const user = request.user!;
      const artifactId = (request.params as { artifactId: string }).artifactId;
      const artifact = await prisma.artifact.findUnique({ where: { id: artifactId } });
      if (!artifact) {
        throw new ApiError(404, ErrorCodes.ARTIFACT_NOT_FOUND, 'Artifact not found');
      }

      await requireEntryAccess(prisma, user, artifact.entryId);
      if (artifact.uploadState !== 'uploaded' || !artifact.storageKey) {
        throw new ApiError(
          409,
          ErrorCodes.UPLOAD_INVALID,
          'Artifact is not available for playback'
        );
      }

      const downloadUrl = await getSignedUrl(
        s3,
        new GetObjectCommand({ Bucket: config.s3.bucket, Key: artifact.storageKey }),
        { expiresIn: DOWNLOAD_URL_TTL_SECONDS }
      );
      reply.header('Cache-Control', 'no-store');
      return { downloadUrl, expiresInSeconds: DOWNLOAD_URL_TTL_SECONDS };
    }
  );

  app.post('/entries/:entryId/artifacts', { preHandler: requireAuth }, async (request, reply) => {
    const user = request.user!;
    const entryId = (request.params as { entryId: string }).entryId;
    const entry = await prisma.practiceEntry.findUnique({ where: { id: entryId } });
    if (!entry || entry.deletedAt) {
      throw new ApiError(404, ErrorCodes.ENTRY_NOT_FOUND, 'Entry not found');
    }
    await requireStudentOwner(prisma, user.id, entry, 'add artifacts');
    const body = requireRecord(request.body, 'body');
    const artifactId = requireClientId(requireField(body?.id, 'id'), 'id');
    const type = requireEnum(requireField(body?.type, 'type'), 'type', ['audio', 'video'] as const);
    const durationSeconds = requireNumber(
      requireField(body?.durationSeconds, 'durationSeconds'),
      'durationSeconds',
      { integer: true, min: 0, max: limits.maxDurationSeconds }
    );
    const expectedSizeBytes = requireNumber(
      requireField(body.sizeBytes, 'sizeBytes'),
      'sizeBytes',
      {
        integer: true,
        min: 1,
        max: limits.maxUploadSizeBytes,
      }
    );
    const result = await withLockedEntry(prisma, entryId, async (tx, lockedEntry) => {
      if (lockedEntry.deletedAt) {
        throw new ApiError(410, ErrorCodes.ENTRY_DELETED, 'Entry has been deleted');
      }
      const existing = await tx.artifact.findUnique({ where: { id: artifactId } });
      if (existing) {
        if (matchesArtifactCreateIdentity(existing, entryId, type, durationSeconds)) {
          // Exact retries are idempotent, including a retry after upload
          // confirmation. Pending legacy rows can be upgraded with the size
          // binding introduced by the upload-hardening migration.
          if (existing.expectedSizeBytes === expectedSizeBytes) {
            return { kind: 'complete' as const, artifact: existing, created: false };
          }
          if (isUpgradeablePendingLegacyArtifact(existing)) {
            const recovered = await tx.artifact.update({
              where: { id: artifactId },
              data: { expectedSizeBytes },
            });
            return { kind: 'complete' as const, artifact: recovered, created: false };
          }
          if (isVerifiableUploadedLegacyArtifact(existing)) {
            return {
              kind: 'verify-legacy-upload' as const,
              storageKey: existing.storageKey!,
            };
          }
        }
        throw new ApiError(409, ErrorCodes.ID_CONFLICT, 'An artifact with this ID already exists');
      }
      if (lockedEntry.status !== 'draft') {
        throw new ApiError(
          409,
          ErrorCodes.ENTRY_LOCKED,
          'Artifacts can only be added to draft entries'
        );
      }
      const created = await withPrismaErrors(
        () =>
          tx.artifact.create({
            data: { id: artifactId, entryId, type, durationSeconds, expectedSizeBytes },
          }),
        { conflictMessage: 'An artifact with this ID already exists' }
      );
      return { kind: 'complete' as const, artifact: created, created: true };
    });

    if (result.kind === 'verify-legacy-upload') {
      let head;
      try {
        head = await withDeadline(
          (abortSignal) =>
            s3.send(new HeadObjectCommand({ Bucket: config.s3.bucket, Key: result.storageKey }), {
              abortSignal,
            }),
          config.dependencyTimeoutMs,
          'S3 HeadObject'
        );
      } catch (error) {
        if (isS3NotFoundError(error)) {
          throw new ApiError(
            409,
            ErrorCodes.ID_CONFLICT,
            'Legacy artifact upload cannot be verified'
          );
        }
        throw new ApiError(
          503,
          ErrorCodes.STORAGE_UNAVAILABLE,
          'Storage is temporarily unavailable'
        );
      }
      if (head.ContentLength !== expectedSizeBytes) {
        throw new ApiError(
          409,
          ErrorCodes.ID_CONFLICT,
          'Legacy artifact size does not match this retry'
        );
      }

      const recovered = await withLockedEntry(prisma, entryId, async (tx) => {
        const current = await tx.artifact.findUnique({ where: { id: artifactId } });
        if (
          !current ||
          !matchesVerifiedLegacyArtifact(current, entryId, type, durationSeconds, result.storageKey)
        ) {
          throw new ApiError(409, ErrorCodes.ID_CONFLICT, 'Artifact changed during retry');
        }
        if (current.expectedSizeBytes === expectedSizeBytes) {
          return current;
        }
        if (current.expectedSizeBytes !== null) {
          throw new ApiError(409, ErrorCodes.ID_CONFLICT, 'Artifact changed during retry');
        }
        return tx.artifact.update({
          where: { id: artifactId },
          data: { expectedSizeBytes },
        });
      });
      return reply.status(200).send(recovered);
    }
    return reply.status(result.created ? 201 : 200).send(result.artifact);
  });

  app.post('/artifacts/:artifactId/presign', { preHandler: requireAuth }, async (request) => {
    const user = request.user!;
    const artifactId = (request.params as { artifactId: string }).artifactId;
    const artifact = await prisma.artifact.findUnique({
      where: { id: artifactId },
      include: { entry: true },
    });
    if (!artifact) {
      throw new ApiError(404, ErrorCodes.ARTIFACT_NOT_FOUND, 'Artifact not found');
    }
    if (artifact.entry.deletedAt) {
      throw new ApiError(410, ErrorCodes.ENTRY_DELETED, 'Entry has been deleted');
    }
    await requireStudentOwner(prisma, user.id, artifact.entry, 'presign artifacts');
    const result = await withPrismaErrors(
      () =>
        withLockedEntry(prisma, artifact.entryId, async (tx, lockedEntry) => {
          if (lockedEntry.deletedAt) {
            throw new ApiError(410, ErrorCodes.ENTRY_DELETED, 'Entry has been deleted');
          }
          if (lockedEntry.status !== 'draft') {
            throw new ApiError(
              409,
              ErrorCodes.ENTRY_LOCKED,
              'Artifacts can only be uploaded while the entry is a draft'
            );
          }

          const current = await tx.artifact.findUnique({ where: { id: artifactId } });
          if (!current || current.entryId !== lockedEntry.id) {
            throw new ApiError(404, ErrorCodes.ARTIFACT_NOT_FOUND, 'Artifact not found');
          }
          if (current.uploadState === 'uploaded') {
            throw new ApiError(409, ErrorCodes.UPLOAD_INVALID, 'Artifact is already uploaded');
          }
          if (!current.expectedSizeBytes) {
            throw new ApiError(
              409,
              ErrorCodes.UPLOAD_INVALID,
              'Artifact is missing its expected upload size'
            );
          }

          const now = new Date();
          if (
            current.confirmationToken !== null &&
            current.uploadExpiresAt !== null &&
            current.uploadExpiresAt > now
          ) {
            throw new ApiError(
              409,
              ErrorCodes.UPLOAD_INVALID,
              'Artifact confirmation is already in progress'
            );
          }
          const canReuseUploadSlot =
            current.uploadState === 'uploading' &&
            current.storageKey !== null &&
            current.confirmationToken === null &&
            current.uploadExpiresAt !== null &&
            current.uploadExpiresAt > now;
          // Preserve a still-valid key across retries, but use a new key after
          // a failed or expired attempt so cleanup cannot delete a newer upload.
          const storageKey = canReuseUploadSlot
            ? current.storageKey!
            : `artifacts/${current.entryId}/${current.id}-${nanoid(12)}`;
          const contentType = current.type === 'video' ? 'video/mp4' : 'audio/m4a';
          const uploadExpiresAt = new Date(now.getTime() + config.s3.presignTtlSeconds * 1000);
          if (!canReuseUploadSlot && current.storageKey !== null) {
            await tx.storageDeletionJob.upsert({
              where: { storageKey: current.storageKey },
              create: { entryId: current.entryId, storageKey: current.storageKey },
              update: {},
            });
          }
          const uploadUrl = await getSignedUrl(
            s3,
            new PutObjectCommand({
              Bucket: config.s3.bucket,
              Key: storageKey,
              ContentType: contentType,
              ContentLength: current.expectedSizeBytes,
            }),
            { expiresIn: config.s3.presignTtlSeconds }
          );

          await tx.artifact.update({
            where: { id: artifactId },
            data: {
              storageKey,
              uploadState: 'uploading',
              uploadExpiresAt,
              confirmationToken: null,
            },
          });
          return {
            uploadUrl,
            storageKey,
            expiresInSeconds: config.s3.presignTtlSeconds,
            requiredHeaders: {
              'Content-Type': contentType,
              'Content-Length': String(current.expectedSizeBytes),
            },
          };
        }),
      {
        notFoundCode: ErrorCodes.ARTIFACT_NOT_FOUND,
        notFoundMessage: 'Artifact not found',
      }
    );
    return result;
  });

  app.post('/artifacts/:artifactId/confirm', { preHandler: requireAuth }, async (request) => {
    const user = request.user!;
    const artifactId = (request.params as { artifactId: string }).artifactId;
    const artifact = await prisma.artifact.findUnique({
      where: { id: artifactId },
      include: { entry: true },
    });
    if (!artifact) {
      throw new ApiError(404, ErrorCodes.ARTIFACT_NOT_FOUND, 'Artifact not found');
    }
    if (artifact.entry.deletedAt) {
      throw new ApiError(410, ErrorCodes.ENTRY_DELETED, 'Entry has been deleted');
    }
    await requireStudentOwner(prisma, user.id, artifact.entry, 'confirm artifacts');
    const confirmationToken = nanoid(24);
    const claimed = await withPrismaErrors(
      () =>
        withLockedEntry(prisma, artifact.entryId, async (tx, lockedEntry) => {
          if (lockedEntry.deletedAt) {
            throw new ApiError(410, ErrorCodes.ENTRY_DELETED, 'Entry has been deleted');
          }
          const current = await tx.artifact.findUnique({ where: { id: artifactId } });
          if (!current || current.entryId !== lockedEntry.id) {
            throw new ApiError(404, ErrorCodes.ARTIFACT_NOT_FOUND, 'Artifact not found');
          }
          if (current.uploadState !== 'uploading') {
            throw new ApiError(
              409,
              ErrorCodes.UPLOAD_INVALID,
              'Artifact must be in uploading state to confirm'
            );
          }
          if (!current.storageKey) {
            throw new ApiError(400, ErrorCodes.MISSING_STORAGE_KEY, 'Artifact missing storage key');
          }
          if (!current.expectedSizeBytes || !current.uploadExpiresAt) {
            throw new ApiError(409, ErrorCodes.UPLOAD_INVALID, 'Artifact upload slot is invalid');
          }
          if (current.uploadExpiresAt <= new Date()) {
            throw new ApiError(409, ErrorCodes.UPLOAD_INVALID, 'Artifact upload slot has expired');
          }
          if (current.confirmationToken !== null) {
            throw new ApiError(
              409,
              ErrorCodes.UPLOAD_INVALID,
              'Artifact confirmation is already in progress'
            );
          }

          await tx.artifact.update({
            where: { id: artifactId },
            data: { confirmationToken },
          });
          return {
            entryId: current.entryId,
            storageKey: current.storageKey,
            expectedSizeBytes: current.expectedSizeBytes,
          };
        }),
      {
        notFoundCode: ErrorCodes.ARTIFACT_NOT_FOUND,
        notFoundMessage: 'Artifact not found',
      }
    );

    let head;
    try {
      head = await withDeadline(
        (abortSignal) =>
          s3.send(new HeadObjectCommand({ Bucket: config.s3.bucket, Key: claimed.storageKey }), {
            abortSignal,
          }),
        config.dependencyTimeoutMs,
        'S3 HeadObject'
      );
    } catch (err) {
      await releaseConfirmationClaim(prisma, artifactId, confirmationToken, request.log);
      if (isS3NotFoundError(err)) {
        request.log.warn(err, 'S3 object was not found during upload confirmation');
        throw new ApiError(409, ErrorCodes.UPLOAD_INVALID, 'Upload not found in storage');
      }
      request.log.error(err, 'S3 HeadObject failed during upload confirmation');
      throw new ApiError(503, ErrorCodes.STORAGE_UNAVAILABLE, 'Storage is temporarily unavailable');
    }
    if (head.ContentLength !== claimed.expectedSizeBytes) {
      await withLockedEntry(prisma, claimed.entryId, async (tx) => {
        const current = await tx.artifact.findUnique({ where: { id: artifactId } });
        if (
          current &&
          current.confirmationToken === confirmationToken &&
          current.storageKey === claimed.storageKey
        ) {
          await tx.storageDeletionJob.upsert({
            where: { storageKey: claimed.storageKey },
            create: { entryId: claimed.entryId, storageKey: claimed.storageKey },
            update: {},
          });
          await tx.artifact.update({
            where: { id: artifactId },
            data: {
              uploadState: 'failed',
              uploadExpiresAt: null,
              confirmationToken: null,
            },
          });
        }
      });
      if ((head.ContentLength ?? 0) > limits.maxUploadSizeBytes) {
        throw new ApiError(
          413,
          ErrorCodes.UPLOAD_INVALID,
          `Upload exceeds maximum size of ${limits.maxUploadSizeBytes} bytes`
        );
      }
      throw new ApiError(
        409,
        ErrorCodes.UPLOAD_INVALID,
        `Uploaded file size does not match the declared ${claimed.expectedSizeBytes} bytes`
      );
    }
    const updated = await withPrismaErrors(
      () =>
        withLockedEntry(prisma, claimed.entryId, async (tx, lockedEntry) => {
          if (lockedEntry.deletedAt) {
            throw new ApiError(410, ErrorCodes.ENTRY_DELETED, 'Entry has been deleted');
          }
          const current = await tx.artifact.findUnique({ where: { id: artifactId } });
          if (
            !current ||
            current.entryId !== lockedEntry.id ||
            current.uploadState !== 'uploading' ||
            current.storageKey !== claimed.storageKey ||
            current.expectedSizeBytes !== claimed.expectedSizeBytes ||
            current.confirmationToken !== confirmationToken ||
            !current.uploadExpiresAt ||
            current.uploadExpiresAt <= new Date()
          ) {
            throw new ApiError(409, ErrorCodes.UPLOAD_INVALID, 'Artifact upload slot changed');
          }
          return tx.artifact.update({
            where: { id: artifactId },
            data: {
              uploadState: 'uploaded',
              uploadExpiresAt: null,
              confirmationToken: null,
              remoteUrl: `s3://${config.s3.bucket}/${claimed.storageKey}`,
            },
          });
        }),
      {
        notFoundCode: ErrorCodes.ARTIFACT_NOT_FOUND,
        notFoundMessage: 'Artifact not found',
      }
    );
    return updated;
  });
}

async function releaseConfirmationClaim(
  prisma: PrismaClient,
  artifactId: string,
  confirmationToken: string,
  logger: { error: (obj: object, msg: string) => void }
) {
  try {
    await prisma.artifact.updateMany({
      where: { id: artifactId, confirmationToken },
      data: { confirmationToken: null },
    });
  } catch (releaseErr) {
    logger.error({ err: releaseErr, artifactId }, 'Failed to release artifact confirmation claim');
  }
}
