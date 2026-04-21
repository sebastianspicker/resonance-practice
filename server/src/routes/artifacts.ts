import type { S3Client } from '@aws-sdk/client-s3';
import { DeleteObjectCommand, HeadObjectCommand, PutObjectCommand } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import type { PrismaClient } from '@prisma/client';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { config, limits } from '../config.js';
import { ErrorCodes } from '../errorCodes.js';
import { ApiError, withPrismaErrors } from '../errors.js';
import {
  requireClientId,
  requireEnum,
  requireField,
  requireNumber,
  requireStudentOwner,
} from '../validation.js';

const MAX_UPLOAD_SIZE = 104857600; // 100 MB

export function registerArtifactRoutes(
  app: FastifyInstance,
  prisma: PrismaClient,
  s3: S3Client,
  requireAuth: (request: FastifyRequest) => Promise<void>
) {
  app.post('/entries/:entryId/artifacts', { preHandler: requireAuth }, async (request, reply) => {
    const user = request.user!;
    const entryId = (request.params as { entryId: string }).entryId;
    const entry = await prisma.practiceEntry.findUnique({ where: { id: entryId } });
    if (!entry || entry.deletedAt) {
      throw new ApiError(404, ErrorCodes.ENTRY_NOT_FOUND, 'Entry not found');
    }
    await requireStudentOwner(prisma, user.id, entry, 'add artifacts');
    if (entry.status !== 'draft') {
      throw new ApiError(
        409,
        ErrorCodes.ENTRY_LOCKED,
        'Artifacts can only be added to draft entries'
      );
    }
    const body = request.body as Record<string, unknown>;
    const artifactId = requireClientId(requireField(body?.id, 'id'), 'id');
    const type = requireEnum(requireField(body?.type, 'type'), 'type', ['audio', 'video'] as const);
    const durationSeconds = requireNumber(
      requireField(body?.durationSeconds, 'durationSeconds'),
      'durationSeconds',
      { min: 0, max: limits.maxDurationSeconds }
    );
    const created = await withPrismaErrors(
      () =>
        prisma.artifact.create({
          data: { id: artifactId, entryId, type, durationSeconds },
        }),
      { conflictMessage: 'An artifact with this ID already exists' }
    );
    return reply.status(201).send(created);
  });

  app.post(
    '/artifacts/:artifactId/presign',
    { preHandler: requireAuth },
    async (request, reply) => {
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
      if (artifact.uploadState === 'uploaded' || artifact.uploadState === 'uploading') {
        return reply
          .code(409)
          .send({ error: { code: 'UPLOAD_INVALID', message: 'Artifact already ' + artifact.uploadState } });
      }
      // Generate new storage key if not already set (avoid overwriting existing)
      const storageKey = artifact.storageKey ?? `artifacts/${artifact.entryId}/${artifact.id}`;
      const contentType = artifact.type === 'audio' ? 'audio/m4a' : 'video/mp4';
      const command = new PutObjectCommand({
        Bucket: config.s3.bucket,
        Key: storageKey,
        ContentType: contentType,
      });
      const uploadUrl = await getSignedUrl(s3, command, {
        expiresIn: config.s3.presignTtlSeconds,
      });
      // uploadState is guaranteed to not be 'uploaded' here (409 guard above)
      await withPrismaErrors(
        () =>
          prisma.artifact.update({
            where: { id: artifactId },
            data: { storageKey, uploadState: 'uploading' },
          }),
        {
          notFoundCode: ErrorCodes.ARTIFACT_NOT_FOUND,
          notFoundMessage: 'Artifact not found',
        }
      );
      return {
        uploadUrl,
        storageKey,
        expiresInSeconds: config.s3.presignTtlSeconds,
        requiredHeaders: { 'Content-Type': contentType },
      };
    }
  );

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
    if (artifact.uploadState !== 'uploading') {
      throw new ApiError(409, ErrorCodes.UPLOAD_INVALID, 'Artifact must be in uploading state to confirm');
    }
    if (!artifact.storageKey) {
      throw new ApiError(400, ErrorCodes.MISSING_STORAGE_KEY, 'Artifact missing storage key');
    }
    let head;
    try {
      head = await s3.send(
        new HeadObjectCommand({ Bucket: config.s3.bucket, Key: artifact.storageKey })
      );
    } catch (err) {
      request.log.warn(err, 'S3 HeadObject failed during upload confirmation');
      throw new ApiError(409, ErrorCodes.UPLOAD_INVALID, 'Upload not found in storage');
    }
    if (!head.ContentLength || head.ContentLength === 0) {
      throw new ApiError(409, ErrorCodes.UPLOAD_INVALID, 'Uploaded file is empty');
    }
    if (head.ContentLength > MAX_UPLOAD_SIZE) {
      try {
        await s3.send(
          new DeleteObjectCommand({ Bucket: config.s3.bucket, Key: artifact.storageKey })
        );
      } catch (deleteErr) {
        request.log.warn(deleteErr, 'Failed to delete oversized S3 object');
      }
      throw new ApiError(
        413,
        ErrorCodes.UPLOAD_INVALID,
        `Upload exceeds maximum size of ${MAX_UPLOAD_SIZE} bytes`
      );
    }
    const updated = await withPrismaErrors(
      () =>
        prisma.artifact.update({
          where: { id: artifactId },
          data: {
            uploadState: 'uploaded',
            remoteUrl: `s3://${config.s3.bucket}/${artifact.storageKey}`,
          },
        }),
      {
        notFoundCode: ErrorCodes.ARTIFACT_NOT_FOUND,
        notFoundMessage: 'Artifact not found',
      }
    );
    return updated;
  });
}
