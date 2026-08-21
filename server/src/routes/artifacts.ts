import type { S3Client } from '@aws-sdk/client-s3';
import type { PrismaClient } from '@prisma/client';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { registerArtifactDownloadRoute } from './artifacts/download.js';
import { registerRetiredLegacyArtifactUploadRoutes } from './artifacts/legacyUploads.js';

export function registerArtifactRoutes(
  app: FastifyInstance,
  prisma: PrismaClient,
  s3: S3Client,
  requireAuth: (request: FastifyRequest) => Promise<void>
) {
  registerArtifactDownloadRoute(app, prisma, s3, requireAuth);
  registerRetiredLegacyArtifactUploadRoutes(app, requireAuth);
}
