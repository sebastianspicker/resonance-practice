/** Versioned artifact session and authorized download transport. */
import type { S3Client } from '@aws-sdk/client-s3';
import type { PrismaClient } from '@prisma/client';
import type { FastifyInstance } from 'fastify';
import { authenticatedUser, type RequireAuth } from '../../../platform/http/authentication.js';
import { createDownloadSession } from '../application/downloads.js';
import { completeArtifactSession } from '../application/sessionCompletion.js';
import { createArtifactSession } from '../application/sessionCreation.js';
import { limits } from '../../../platform/config.js';
import { ErrorCodes } from '../../../platform/http/errorCodes.js';
import { ApiError } from '../../../platform/http/errors.js';
import {
  requireClientId,
  requireEnum,
  requireNumber,
  requireRecord,
} from '../../../platform/http/input.js';
import { apiRateLimit } from '../../../platform/http/rateLimit.js';

export function registerMediaRoutes(
  app: FastifyInstance,
  prisma: PrismaClient,
  s3: S3Client,
  requireAuth: RequireAuth
) {
  app.post(
    '/api/v1/artifact-sessions',
    { preHandler: requireAuth, config: { rateLimit: apiRateLimit } },
    async (request) => {
      const body = requireRecord(request.body, 'body');
      return createArtifactSession(prisma, s3, {
        userId: authenticatedUser(request).id,
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
        checksumSha256: requireChecksumSha256(body.checksumSha256),
        baseVersion: requireNumber(body.baseVersion, 'baseVersion', { integer: true, min: 1 }),
      });
    }
  );

  app.post(
    '/api/v1/artifact-sessions/:sessionId/complete',
    { preHandler: requireAuth, config: { rateLimit: apiRateLimit } },
    async (request) =>
      completeArtifactSession(
        prisma,
        s3,
        authenticatedUser(request).id,
        requireClientId((request.params as { sessionId: string }).sessionId, 'sessionId')
      )
  );

  app.post(
    '/api/v1/artifacts/:artifactId/download-session',
    { preHandler: requireAuth, config: { rateLimit: apiRateLimit } },
    async (request, reply) => {
      const artifactId = requireClientId(
        (request.params as { artifactId: string }).artifactId,
        'artifactId'
      );
      const session = await createDownloadSession(
        prisma,
        s3,
        authenticatedUser(request).id,
        artifactId
      );
      reply.header('Cache-Control', 'no-store');
      return session;
    }
  );
}

function requireChecksumSha256(value: unknown): string {
  if (typeof value !== 'string' || !/^[A-Za-z0-9+/]{43}=$/.test(value)) {
    throw new ApiError(400, ErrorCodes.VALIDATION_ERROR, 'Invalid checksumSha256');
  }
  if (Buffer.from(value, 'base64').length !== 32) {
    throw new ApiError(400, ErrorCodes.VALIDATION_ERROR, 'Invalid checksumSha256');
  }
  return value;
}
