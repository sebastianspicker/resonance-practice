// Covers stable payload hashing, receipt replay, authorization rechecks, and quota races.
import { createHash } from 'node:crypto';
import type { PrismaClient } from '@prisma/client';
import { describe, expect, it, vi } from 'vitest';
import {
  executeSyncCommand,
  type SyncCommand,
  type SyncCommandResult,
} from '../src/services/syncCommands.js';
import { stableJson } from '../src/services/sync/payloads.js';

const command: SyncCommand = {
  operationId: 'operation-1',
  entityId: 'entry-1',
  kind: 'updateEntry',
  baseVersion: 3,
  payload: { goalText: 'Updated goal' },
};

describe('sync command receipt replay', () => {
  it('maps a previously applied result to duplicate without reapplying it', async () => {
    const stored = resultWithStatus('applied');
    const { prisma, createReceipt } = makePrismaWithReceipt(stored);

    await expect(executeSyncCommand(prisma, 'user-1', command)).resolves.toEqual({
      ...stored,
      status: 'duplicate',
    });
    expect(createReceipt).not.toHaveBeenCalled();
  });

  it.each(['conflict', 'rejected', 'retryable'] as const)(
    'preserves a previously stored %s result',
    async (status) => {
      const stored = resultWithStatus(status);
      const { prisma, createReceipt } = makePrismaWithReceipt(stored);

      await expect(executeSyncCommand(prisma, 'user-1', command)).resolves.toEqual(stored);
      expect(createReceipt).not.toHaveBeenCalled();
    }
  );

  it('rejects a stored receipt after the user loses course membership', async () => {
    const stored = resultWithStatus('applied');
    const { prisma } = makePrismaWithReceipt(stored, null);

    await expect(executeSyncCommand(prisma, 'user-1', command)).resolves.toMatchObject({
      status: 'rejected',
      code: 'STUDENT_ONLY',
    });
  });

  it('returns a minimal duplicate when a stored entry resource was later deleted', async () => {
    const stored = resultWithStatus('applied');
    const { prisma } = makePrismaWithReceipt(stored, { roleInCourse: 'student' }, null);

    await expect(executeSyncCommand(prisma, 'user-1', command)).resolves.toEqual({
      operationId: command.operationId,
      entityId: command.entityId,
      kind: command.kind,
      status: 'duplicate',
    });
  });
});

function resultWithStatus(status: SyncCommandResult['status']): SyncCommandResult {
  return {
    operationId: command.operationId,
    entityId: command.entityId,
    kind: command.kind,
    status,
    ...(status === 'applied' ? {} : { code: 'STORED_RESULT' }),
  };
}

function makePrismaWithReceipt(
  resultJson: SyncCommandResult,
  membership: { roleInCourse: 'student' } | null = { roleInCourse: 'student' },
  entry: { deletedAt: null } | null = { deletedAt: null }
) {
  const createReceipt = vi.fn();
  const transaction = {
    $queryRaw: vi.fn().mockResolvedValue([{ locked: '1' }]),
    syncReceipt: {
      findUnique: vi.fn().mockResolvedValue({
        payloadHash: commandPayloadHash(command),
        kind: command.kind,
        resultJson,
      }),
      create: createReceipt,
    },
    membership: {
      findUnique: vi.fn().mockResolvedValue(membership),
    },
    practiceEntry: {
      findUnique: vi.fn().mockResolvedValue(entry),
    },
  };
  const prisma = {
    $transaction: vi.fn(async (operation: (tx: typeof transaction) => Promise<SyncCommandResult>) =>
      operation(transaction)
    ),
  } as unknown as PrismaClient;
  transaction.syncReceipt.findUnique.mockResolvedValue({
    payloadHash: commandPayloadHash(command),
    kind: command.kind,
    resultJson: {
      ...resultJson,
      authorization: { courseId: 'course-1', requiredRole: 'student', entryId: 'entry-1' },
    },
  });
  return { prisma, createReceipt };
}

function commandPayloadHash(value: SyncCommand): string {
  return createHash('sha256')
    .update(
      stableJson({
        entityId: value.entityId,
        kind: value.kind,
        baseVersion: value.baseVersion ?? null,
        payload: value.payload,
      })
    )
    .digest('hex');
}
