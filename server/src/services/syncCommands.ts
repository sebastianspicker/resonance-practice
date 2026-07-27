/** Durable command receipts, replay detection, and FIFO sync orchestration. */
import { createHash } from 'node:crypto';
import type { Prisma, PrismaClient } from '@prisma/client';
import { ErrorCodes } from '../errorCodes.js';
import { ApiError, isPrismaError } from '../errors.js';
import { lockOperationIdentity } from './entryTransaction.js';
import {
  type SyncCommand,
  type SyncCommandResult,
  type SyncCommandStatus,
} from './sync/contract.js';
import {
  createEntry,
  deleteEntry,
  updateEntry,
  replaceCaptureMarkers,
  submitEntry,
  baseResult,
} from './sync/entryCommands.js';
import { createFeedback } from './sync/feedbackCommands.js';
import { stableJson } from './sync/payloads.js';

const SYNC_RECEIPT_RETENTION_MS = 7 * 24 * 60 * 60 * 1000;
export const MAX_SYNC_RECEIPTS_PER_USER = 500;
const SYNC_RECEIPT_CLEANUP_BATCH = 1_000;

type ReceiptAuthorization = {
  courseId: string;
  requiredRole: 'student' | 'teacher';
  entryId?: string;
};
type StoredSyncReceipt = SyncCommandResult & { authorization: ReceiptAuthorization };

export type { SyncCommand, SyncCommandResult } from './sync/contract.js';
export { parseSyncCommand } from './sync/contract.js';

/**
 * Execute one idempotent command and persist a replayable result. Domain
 * conflicts are data outcomes; infrastructure failures remain retryable.
 */
export async function executeSyncCommand(
  prisma: PrismaClient,
  userId: string,
  command: SyncCommand
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
      return apiErrorResult(command, error);
    }
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

  const authorization = await receiptAuthorization(tx, command);
  const result = await applyOrRejectCommand(tx, userId, command);
  if (result.status === 'applied') {
    await persistSyncReceipt(tx, userId, command, hash, result, authorization);
  }
  return result;
}

async function replaySyncReceipt(
  tx: Prisma.TransactionClient,
  userId: string,
  command: SyncCommand,
  hash: string
): Promise<SyncCommandResult | null> {
  const receipt = await tx.syncReceipt.findUnique({
    where: { userId_operationId: { userId, operationId: command.operationId } },
  });
  if (!receipt) return null;
  if (receipt.payloadHash !== hash || receipt.kind !== command.kind) {
    return operationReuseResult(command);
  }

  const stored = receipt.resultJson as unknown as StoredSyncReceipt;
  const { authorization, ...storedResult } = stored;
  await authorizeReceiptReplay(tx, userId, authorization);
  if (authorization.entryId && !(await isCurrentEntry(tx, authorization.entryId))) {
    return { ...baseResult(command, 'duplicate') };
  }
  return {
    ...storedResult,
    status: storedResult.status === 'applied' ? 'duplicate' : storedResult.status,
  };
}

async function persistSyncReceipt(
  tx: Prisma.TransactionClient,
  userId: string,
  command: SyncCommand,
  hash: string,
  result: SyncCommandResult,
  authorization: ReceiptAuthorization
): Promise<void> {
  await admitSyncReceipt(tx, userId);
  await tx.syncReceipt.create({
    data: {
      userId,
      operationId: command.operationId,
      kind: command.kind,
      payloadHash: hash,
      resultJson: { ...result, authorization } as Prisma.InputJsonValue,
    },
  });
}

/** Prune expired receipts in bounded batches without evicting active idempotency state. */
export async function cleanupSyncReceipts(
  prisma: PrismaClient,
  options: { now?: Date; limit?: number } = {}
): Promise<number> {
  const now = options.now ?? new Date();
  const limit = Math.min(
    Math.max(options.limit ?? SYNC_RECEIPT_CLEANUP_BATCH, 1),
    SYNC_RECEIPT_CLEANUP_BATCH
  );
  const expiresBefore = new Date(now.getTime() - SYNC_RECEIPT_RETENTION_MS);
  const receipts = await prisma.syncReceipt.findMany({
    where: { createdAt: { lt: expiresBefore } },
    select: { id: true },
    orderBy: { createdAt: 'asc' },
    take: limit,
  });
  if (receipts.length === 0) return 0;
  await prisma.syncReceipt.deleteMany({
    where: { id: { in: receipts.map((receipt) => receipt.id) } },
  });
  return receipts.length;
}

/** Advisory lock makes receipt cleanup and quota admission atomic per user. */
async function admitSyncReceipt(tx: Prisma.TransactionClient, userId: string): Promise<void> {
  // A per-user advisory lock makes count-and-admit enforcement deterministic
  // across concurrent operation IDs for the same authenticated user.
  await tx.$queryRaw<Array<{ locked: string }>>`
    SELECT pg_advisory_xact_lock(hashtextextended(${userId}, 3))::text AS "locked"
  `;
  const expiresBefore = new Date(Date.now() - SYNC_RECEIPT_RETENTION_MS);
  await tx.syncReceipt.deleteMany({ where: { userId, createdAt: { lt: expiresBefore } } });
  assertSyncReceiptCapacity(await tx.syncReceipt.count({ where: { userId } }));
}

export function assertSyncReceiptCapacity(receiptCount: number): void {
  if (receiptCount >= MAX_SYNC_RECEIPTS_PER_USER) {
    throw new ApiError(
      429,
      ErrorCodes.RATE_LIMITED,
      'Sync receipt quota reached; retry after receipts expire'
    );
  }
}

async function authorizeReceiptReplay(
  tx: Prisma.TransactionClient,
  userId: string,
  authorization: ReceiptAuthorization
): Promise<void> {
  await requireReplayMembership(tx, userId, authorization.courseId, authorization.requiredRole);
}

async function receiptAuthorization(
  tx: Prisma.TransactionClient,
  command: SyncCommand
): Promise<ReceiptAuthorization> {
  switch (command.kind) {
    case 'createEntry':
      return createEntryReceiptAuthorization(command);
    case 'createFeedback':
      return feedbackReceiptAuthorization(tx, command.payload);
    default:
      return entryReceiptAuthorization(tx, command.entityId, 'student');
  }
}

function createEntryReceiptAuthorization(command: SyncCommand) {
  const courseId =
    typeof command.payload.courseId === 'string' ? command.payload.courseId : undefined;
  if (!courseId) {
    throw new ApiError(400, ErrorCodes.VALIDATION_ERROR, 'Invalid create entry receipt');
  }
  return { courseId, requiredRole: 'student' as const, entryId: command.entityId };
}

async function feedbackReceiptAuthorization(
  tx: Prisma.TransactionClient,
  payload: Record<string, unknown>
): Promise<ReceiptAuthorization> {
  const targetId = typeof payload.targetId === 'string' ? payload.targetId : undefined;
  if (payload.targetType === 'entry' && targetId) {
    return entryReceiptAuthorization(tx, targetId, 'teacher');
  }
  if (payload.targetType === 'artifact' && targetId) {
    const artifact = await tx.artifact.findUnique({
      where: { id: targetId },
      select: { entryId: true },
    });
    if (!artifact) throw new ApiError(404, ErrorCodes.ARTIFACT_NOT_FOUND, 'Artifact not found');
    return entryReceiptAuthorization(tx, artifact.entryId, 'teacher');
  }
  throw new ApiError(400, ErrorCodes.VALIDATION_ERROR, 'Invalid feedback receipt');
}

async function entryReceiptAuthorization(
  tx: Prisma.TransactionClient,
  entryId: string,
  requiredRole: 'student' | 'teacher'
): Promise<ReceiptAuthorization> {
  const entry = await tx.practiceEntry.findUnique({
    where: { id: entryId },
    select: { courseId: true },
  });
  if (!entry) throw new ApiError(404, ErrorCodes.ENTRY_NOT_FOUND, 'Entry not found');
  return { courseId: entry.courseId, requiredRole, entryId };
}

async function isCurrentEntry(tx: Prisma.TransactionClient, entryId: string): Promise<boolean> {
  const entry = await tx.practiceEntry.findUnique({
    where: { id: entryId },
    select: { deletedAt: true },
  });
  return entry !== null && entry.deletedAt === null;
}

async function requireReplayMembership(
  tx: Prisma.TransactionClient,
  userId: string,
  courseId: string,
  requiredRole: 'student' | 'teacher'
): Promise<void> {
  const membership = await tx.membership.findUnique({
    where: { userId_courseId: { userId, courseId } },
  });
  if (!membership || membership.roleInCourse !== requiredRole) {
    throw new ApiError(
      403,
      requiredRole === 'teacher' ? ErrorCodes.TEACHER_ONLY : ErrorCodes.STUDENT_ONLY,
      `Only course ${requiredRole}s can replay this command`
    );
  }
}

async function applyOrRejectCommand(
  tx: Prisma.TransactionClient,
  userId: string,
  command: SyncCommand
): Promise<SyncCommandResult> {
  try {
    return await applyCommand(tx, userId, command);
  } catch (error) {
    if (!(error instanceof ApiError) || error.statusCode >= 500) throw error;
    return apiErrorResult(command, error);
  }
}

async function applyCommand(
  tx: Prisma.TransactionClient,
  userId: string,
  command: SyncCommand
): Promise<SyncCommandResult> {
  switch (command.kind) {
    case 'createEntry':
      return createEntry(tx, userId, command);
    case 'updateEntry':
      return updateEntry(tx, userId, command);
    case 'replaceCaptureMarkers':
      return replaceCaptureMarkers(tx, userId, command);
    case 'submitEntry':
      return submitEntry(tx, userId, command);
    case 'deleteEntry':
      return deleteEntry(tx, userId, command);
    case 'createFeedback':
      return createFeedback(tx, userId, command);
  }
}

function apiErrorResult(command: SyncCommand, error: ApiError): SyncCommandResult {
  const status: SyncCommandStatus =
    error.code === ErrorCodes.VERSION_CONFLICT ? 'conflict' : 'rejected';
  return { ...baseResult(command, status), code: error.code, message: error.message };
}

function retryableResult(command: SyncCommand, message: string): SyncCommandResult {
  return { ...baseResult(command, 'retryable'), code: ErrorCodes.INTERNAL_ERROR, message };
}

function operationReuseResult(command: SyncCommand): SyncCommandResult {
  return {
    ...baseResult(command, 'rejected'),
    code: ErrorCodes.OPERATION_REUSED,
    message: 'operationId was already used with different content',
  };
}

function commandHash(command: SyncCommand): string {
  return createHash('sha256')
    .update(
      stableJson({
        entityId: command.entityId,
        kind: command.kind,
        baseVersion: command.baseVersion ?? null,
        payload: command.payload,
      })
    )
    .digest('hex');
}
