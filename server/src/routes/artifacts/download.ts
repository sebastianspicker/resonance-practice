import type { S3Client } from '@aws-sdk/client-s3';
import { GetObjectCommand } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import type { PrismaClient } from '@prisma/client';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { config } from '../../config.js';
import { ErrorCodes } from '../../errorCodes.js';
import { ApiError } from '../../errors.js';
import { requireEntryAccess } from '../../validation.js';

const DOWNLOAD_URL_TTL_SECONDS = 900;

export function registerArtifactDownloadRoute(
  app: FastifyInstance,
  prisma: PrismaClient,
  s3: S3Client,
  requireAuth: (request: FastifyRequest) => Promise<void>
) {
  app.get(
    '/artifacts/:artifactId/download',
    { preHandler: requireAuth },
    async (request, reply) => {
      const artifactId = (request.params as { artifactId: string }).artifactId;
      const artifact = await prisma.artifact.findUnique({ where: { id: artifactId } });
      if (!artifact) throw new ApiError(404, ErrorCodes.ARTIFACT_NOT_FOUND, 'Artifact not found');
      await requireEntryAccess(prisma, request.user!, artifact.entryId);
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
}
