/** Durable command receipts: hashing, replay detection, quota admission, and retention. */
import { createHash } from 'node:crypto';
import type { Prisma, PrismaClient } from '@prisma/client';
import { ErrorCodes } from '../../../platform/http/errorCodes.js';
import { ApiError } from '../../../platform/http/errors.js';
import {
  advisoryTransactionLock,
  AdvisoryLockNamespace,
} from '../../../platform/database/advisoryLocks.js';
import { requireCourseMembership } from '../../courses/application/authorization.js';
import type { CommandReceiptScope } from '../../entries/application/commands.js';
import type { SyncCommand, SyncCommandResult } from './contract.js';
import { baseResult } from './dispatch.js';

const SYNC_RECEIPT_RETENTION_MS = 7 * 24 * 60 * 60 * 1000;
export const MAX_SYNC_RECEIPTS_PER_USER = 500;
const SYNC_RECEIPT_CLEANUP_BATCH = 1_000;

type StoredSyncReceipt = SyncCommandResult & { authorization: CommandReceiptScope };

export async function replaySyncReceipt(
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
  await requireCourseMembership(
    tx,
    userId,
    authorization.courseId,
    authorization.requiredRole,
    `Only course ${authorization.requiredRole}s can replay this command`
  );
  if (authorization.entryId && !(await isCurrentEntry(tx, authorization.entryId))) {
    return { ...baseResult(command, 'duplicate') };
  }
  return {
    ...storedResult,
    status: storedResult.status === 'applied' ? 'duplicate' : storedResult.status,
  };
}

export async function persistSyncReceipt(
  tx: Prisma.TransactionClient,
  userId: string,
  command: SyncCommand,
  hash: string,
  result: SyncCommandResult,
  authorization: CommandReceiptScope
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
export async function admitSyncReceipt(
  tx: Prisma.TransactionClient,
  userId: string
): Promise<void> {
  // A per-user advisory lock makes count-and-admit enforcement deterministic
  // across concurrent operation IDs for the same authenticated user.
  await advisoryTransactionLock(tx, userId, AdvisoryLockNamespace.userQuota);
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

async function isCurrentEntry(tx: Prisma.TransactionClient, entryId: string): Promise<boolean> {
  const entry = await tx.practiceEntry.findUnique({
    where: { id: entryId },
    select: { deletedAt: true },
  });
  return entry !== null && entry.deletedAt === null;
}

function operationReuseResult(command: SyncCommand): SyncCommandResult {
  return {
    ...baseResult(command, 'rejected'),
    code: ErrorCodes.OPERATION_REUSED,
    message: 'operationId was already used with different content',
  };
}

export function commandHash(command: SyncCommand): string {
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

/** Canonicalize object-key order so idempotency hashes are stable across clients. */
function stableJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(',')}]`;
  if (value !== null && typeof value === 'object') {
    const record = value as Record<string, unknown>;
    return `{${Object.keys(record)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${stableJson(record[key])}`)
      .join(',')}}`;
  }
  return JSON.stringify(value) ?? 'null';
}
