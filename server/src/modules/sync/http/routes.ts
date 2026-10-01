/** Ordered v1 command transport. Read and media contracts live with their owning modules. */
import type { PrismaClient } from '@prisma/client';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { ErrorCodes } from '../../../platform/http/errorCodes.js';
import { ApiError } from '../../../platform/http/errors.js';
import { requireRecord } from '../../../platform/http/input.js';
import { createSyncAdmission } from '../application/sync/admission.js';
import {
  executeSyncCommand,
  parseSyncCommand,
  type SyncCommandResult,
} from '../application/commands.js';

export function registerSyncRoutes(
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
    for (const command of commands) {
      results.push(await executeSyncCommand(prisma, request.user!.id, command));
    }
    return { results };
  });
}
