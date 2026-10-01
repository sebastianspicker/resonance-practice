/** Ordered v1 command transport. Read and media contracts live with their owning modules. */
import type { PrismaClient } from '@prisma/client';
import type { FastifyInstance } from 'fastify';
import { authenticatedUser, type RequireAuth } from '../../../platform/http/authentication.js';
import { ErrorCodes } from '../../../platform/http/errorCodes.js';
import { ApiError } from '../../../platform/http/errors.js';
import { requireRecord } from '../../../platform/http/input.js';
import { createSyncAdmission } from '../application/admission.js';
import { executeSyncCommand } from '../application/commands.js';
import {
  MAX_SYNC_COMMANDS_PER_BATCH,
  parseSyncCommand,
  type SyncCommandResult,
} from '../application/contract.js';

export function registerSyncRoutes(
  app: FastifyInstance,
  prisma: PrismaClient,
  requireAuth: RequireAuth
) {
  const admission = createSyncAdmission();
  app.post('/api/v1/sync/commands', { preHandler: requireAuth }, async (request) => {
    admission.admitRequest(authenticatedUser(request).id);
    const body = requireRecord(request.body, 'body');
    if (
      !Array.isArray(body.commands) ||
      body.commands.length === 0 ||
      body.commands.length > MAX_SYNC_COMMANDS_PER_BATCH
    ) {
      throw new ApiError(
        400,
        ErrorCodes.VALIDATION_ERROR,
        `commands must contain between 1 and ${MAX_SYNC_COMMANDS_PER_BATCH} commands`
      );
    }
    admission.admitCommands(authenticatedUser(request).id, body.commands.length);
    const commands = body.commands.map(parseSyncCommand);
    const results: SyncCommandResult[] = [];
    for (const command of commands) {
      results.push(await executeSyncCommand(prisma, authenticatedUser(request).id, command));
    }
    return { results };
  });
}
