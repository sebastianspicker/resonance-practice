import type { FastifyInstance, FastifyRequest } from 'fastify';
import { ErrorCodes } from '../../errorCodes.js';
import { ApiError } from '../../errors.js';

const LEGACY_UPLOAD_MESSAGE = 'Legacy artifact uploads are retired; use /api/v1/artifact-sessions';

export function registerRetiredLegacyArtifactUploadRoutes(
  app: FastifyInstance,
  requireAuth: (request: FastifyRequest) => Promise<void>
) {
  const retired = async () => {
    throw new ApiError(410, ErrorCodes.UPLOAD_INVALID, LEGACY_UPLOAD_MESSAGE);
  };
  app.post('/entries/:entryId/artifacts', { preHandler: requireAuth }, retired);
  app.post('/artifacts/:artifactId/presign', { preHandler: requireAuth }, retired);
  app.post('/artifacts/:artifactId/confirm', { preHandler: requireAuth }, retired);
}
