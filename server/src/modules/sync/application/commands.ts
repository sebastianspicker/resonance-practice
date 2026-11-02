/** Idempotent v1 command gateway: receipt replay, owning-module dispatch, and receipt persistence. */
import type { Prisma, PrismaClient } from '@prisma/client';
import type { FastifyBaseLogger } from 'fastify';
import { ApiError, isPrismaError } from '../../../platform/http/errors.js';
import { lockOperationIdentity } from '../../../platform/database/advisoryLocks.js';
import type { SyncCommand, SyncCommandResult } from './contract.js';
import {
  apiErrorResult,
  applyOrRejectCommand,
  commandReceiptScope,
  retryableResult,
} from './dispatch.js';
import { commandHash, persistSyncReceipt, replaySyncReceipt } from './receipts.js';

/**
 * Execute one idempotent command and persist a replayable result. Domain
 * conflicts are data outcomes; infrastructure failures remain retryable.
 */
export async function executeSyncCommand(
  prisma: PrismaClient,
  userId: string,
  command: SyncCommand,
  log: Pick<FastifyBaseLogger, 'error'>
): Promise<SyncCommandResult> {
  const hash = commandHash(command);
  try {
    return await prisma.$transaction((tx) => executeSyncTransaction(tx, userId, command, hash));
  } catch (error) {
    if (isPrismaError(error, 'P2002')) {
      return retryableResult(command, 'Receipt contention; retry the operation');
    }
    if (error instanceof ApiError) {
      if (error.statusCode === 429) throw error;
      if (error.statusCode >= 500) {
        log.error(
          { err: error, operationId: command.operationId, kind: command.kind },
          'Sync command failed with a server error'
        );
      }
      return apiErrorResult(command, error);
    }
    log.error(
      { err: error, operationId: command.operationId, kind: command.kind },
      'Sync command failed unexpectedly'
    );
    return retryableResult(command, 'Unexpected error');
  }
}

async function executeSyncTransaction(
  tx: Prisma.TransactionClient,
  userId: string,
  command: SyncCommand,
  hash: string
): Promise<SyncCommandResult> {
  await lockOperationIdentity(tx, userId, command.operationId);
  const replay = await replaySyncReceipt(tx, userId, command, hash);
  if (replay) return replay;

  const authorization = await commandReceiptScope(tx, command);
  const result = await applyOrRejectCommand(tx, userId, command);
  if (result.status === 'applied') {
    await persistSyncReceipt(tx, userId, command, hash, result, authorization);
  }
  return result;
}
