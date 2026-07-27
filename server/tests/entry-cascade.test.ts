// Unit-tests transactional entry deletion, tombstones, and durable storage cleanup races.
import { describe, expect, it, vi, beforeEach } from 'vitest';
import { S3Client, DeleteObjectCommand } from '@aws-sdk/client-s3';
import { mockClient } from 'aws-sdk-client-mock';
import {
  cascadeDeleteEntry,
  cleanupFailedArtifacts,
  expireStaleArtifactUploads,
  retryStorageDeletionJobs,
} from '../src/services/entryCascade.js';
import { artifactCompletionClaimLeaseMs } from '../src/services/entryTransaction.js';
import { ApiError } from '../src/errors.js';

/**
 * Tests for entryCascade.ts:
 * - cascadeDeleteEntry: entry not found (P2025)
 * - cascadeDeleteEntry: successful cascade with artifacts/feedback/markers
 */

const s3Mock = mockClient(S3Client);

function staleArtifactPrisma(tx: object, candidate: { id: string; entryId: string }) {
  return {
    artifact: {
      findMany: vi.fn().mockResolvedValue([candidate]),
    },
    $transaction: vi.fn(async (operation: (client: object) => unknown) => operation(tx)),
  } as any;
}

function emptyCascadeTransaction(
  entryId: string,
  entryDelete: ReturnType<typeof vi.fn> = vi.fn().mockResolvedValue({ id: entryId })
) {
  const artifactDelete = vi.fn();
  return {
    artifactDelete,
    tx: {
      $queryRaw: vi.fn().mockResolvedValue([{ id: entryId }]),
      artifact: { findMany: vi.fn().mockResolvedValue([]), deleteMany: artifactDelete },
      feedback: { findMany: vi.fn().mockResolvedValue([]), deleteMany: vi.fn() },
      marker: { deleteMany: vi.fn() },
      practiceEntry: {
        findUnique: vi.fn().mockResolvedValue({ id: entryId }),
        delete: entryDelete,
      },
      storageDeletionJob: { createMany: vi.fn() },
      deletedEntryTombstone: { upsert: vi.fn().mockResolvedValue({ id: entryId }) },
    },
  };
}

function staleUploadTransaction(
  now: Date,
  update: ReturnType<typeof vi.fn>,
  upsert: ReturnType<typeof vi.fn>,
  options: {
    storageKey: string;
    uploadExpiresAt: Date | null;
    createdAt?: Date;
    artifactUploadSession: Record<string, unknown>;
  }
) {
  return {
    $queryRaw: vi.fn().mockResolvedValue([{ id: 'entry-expired' }]),
    practiceEntry: {
      findUnique: vi.fn().mockResolvedValue({ id: 'entry-expired', deletedAt: null }),
      update: vi.fn().mockResolvedValue({}),
    },
    artifact: {
      findUnique: vi.fn().mockResolvedValue({
        id: 'artifact-expired',
        entryId: 'entry-expired',
        uploadState: 'uploading',
        storageKey: options.storageKey,
        uploadExpiresAt: options.uploadExpiresAt,
        createdAt: options.createdAt ?? now,
      }),
      update,
    },
    storageDeletionJob: { findUnique: vi.fn().mockResolvedValue(null), upsert },
    artifactUploadSession: options.artifactUploadSession,
  };
}

describe('entryCascade', () => {
  beforeEach(() => {
    s3Mock.reset();
  });

  describe('retryStorageDeletionJobs', () => {
    it('removes successfully deleted jobs and retains failed jobs with retry state', async () => {
      s3Mock.on(DeleteObjectCommand).resolvesOnce({}).rejectsOnce(new Error('S3 network error'));
      const prisma = {
        storageDeletionJob: {
          findMany: vi.fn().mockResolvedValue([
            {
              id: 'job-success',
              storageKey: 'success-key',
              attemptCount: 0,
              createdAt: new Date(),
            },
            {
              id: 'job-fail',
              storageKey: 'failure-key',
              attemptCount: 0,
              createdAt: new Date(),
            },
          ]),
          deleteMany: vi.fn().mockResolvedValue({ count: 1 }),
          updateMany: vi.fn().mockResolvedValue({ count: 1 }),
        },
      } as any;
      const logger = { error: vi.fn() };

      await retryStorageDeletionJobs(prisma, new S3Client({}), logger);

      expect(prisma.storageDeletionJob.deleteMany).toHaveBeenCalledWith({
        where: { id: 'job-success' },
      });
      expect(prisma.storageDeletionJob.updateMany).toHaveBeenCalledWith({
        where: { id: 'job-fail' },
        data: {
          attemptCount: { increment: 1 },
          lastError: 'S3 network error',
          nextAttemptAt: expect.any(Date),
        },
      });
      expect(logger.error).toHaveBeenCalledWith(
        expect.objectContaining({ jobId: 'job-fail', storageKey: 'failure-key' }),
        'Failed to delete queued S3 object'
      );
    });

    it('times out a stuck delete and preserves its durable retry job', async () => {
      s3Mock.on(DeleteObjectCommand).callsFake(() => new Promise(() => {}));
      const prisma = {
        storageDeletionJob: {
          findMany: vi.fn().mockResolvedValue([
            {
              id: 'job-timeout',
              storageKey: 'stuck-key',
              attemptCount: 0,
              createdAt: new Date(),
            },
          ]),
          deleteMany: vi.fn(),
          updateMany: vi.fn().mockResolvedValue({ count: 1 }),
        },
      } as any;
      const logger = { error: vi.fn() };

      await expect(
        retryStorageDeletionJobs(prisma, new S3Client({}), logger, { requestTimeoutMs: 10 })
      ).resolves.toBe(1);
      expect(prisma.storageDeletionJob.deleteMany).not.toHaveBeenCalled();
      expect(prisma.storageDeletionJob.updateMany).toHaveBeenCalledWith({
        where: { id: 'job-timeout' },
        data: expect.objectContaining({
          attemptCount: { increment: 1 },
          lastError: 'S3 DeleteObject timed out after 10ms',
          nextAttemptAt: expect.any(Date),
        }),
      });
    });
  });

  describe('expireStaleArtifactUploads', () => {
    it('skips an upload that disappears after candidate selection', async () => {
      const update = vi.fn();
      const tx = {
        $queryRaw: vi.fn().mockResolvedValue([{ id: 'entry-missing-artifact' }]),
        practiceEntry: {
          findUnique: vi.fn().mockResolvedValue({ id: 'entry-missing-artifact', deletedAt: null }),
        },
        artifact: { findUnique: vi.fn().mockResolvedValue(null), update },
      };
      const prisma = {
        artifact: {
          findMany: vi
            .fn()
            .mockResolvedValue([{ id: 'artifact-gone', entryId: 'entry-missing-artifact' }]),
        },
        $transaction: vi.fn(async (operation: (client: typeof tx) => unknown) => operation(tx)),
      } as any;

      await expect(expireStaleArtifactUploads(prisma)).resolves.toBe(0);
      expect(update).not.toHaveBeenCalled();
    });

    it('queues the old key and retains the session through the cleanup grace period', async () => {
      const now = new Date('2026-07-15T12:00:00.000Z');
      const upsert = vi.fn().mockResolvedValue({ id: 'job-1' });
      const update = vi.fn().mockResolvedValue({ id: 'artifact-expired' });
      const tx = staleUploadTransaction(now, update, upsert, {
        storageKey: 'artifacts/expired-key',
        uploadExpiresAt: null,
        artifactUploadSession: {
          findMany: vi.fn().mockResolvedValue([]),
          deleteMany: vi.fn().mockResolvedValue({ count: 1 }),
        },
      });
      const prisma = staleArtifactPrisma(tx, {
        id: 'artifact-expired',
        entryId: 'entry-expired',
      });

      await expect(expireStaleArtifactUploads(prisma, { now })).resolves.toBe(0);
      expect(upsert).toHaveBeenCalledWith({
        where: { storageKey: 'artifacts/expired-key' },
        create: {
          entryId: 'entry-expired',
          storageKey: 'artifacts/expired-key',
          nextAttemptAt: new Date('2026-07-15T12:05:00.000Z'),
        },
        update: {
          nextAttemptAt: new Date('2026-07-15T12:05:00.000Z'),
        },
      });
      expect(update).not.toHaveBeenCalled();

      await expect(
        expireStaleArtifactUploads(prisma, {
          now: new Date('2026-07-15T12:05:00.000Z'),
        })
      ).resolves.toBe(1);
      expect(update).toHaveBeenCalledWith({
        where: { id: 'artifact-expired' },
        data: {
          uploadState: 'failed',
          storageKey: null,
          remoteUrl: null,
          uploadExpiresAt: null,
          confirmationToken: null,
          failedAt: new Date('2026-07-15T12:05:00.000Z'),
        },
      });
      expect(upsert.mock.invocationCallOrder[0]).toBeLessThan(update.mock.invocationCallOrder[0]!);
    });

    it('keeps claim records and final-key cleanup dormant while CopyObject may be in flight', async () => {
      const now = new Date('2026-07-15T12:00:00.000Z');
      const claimedAt = new Date(now.getTime() - 1_000);
      const expiresAt = new Date(now.getTime() - 500);
      const finalKey = 'artifacts/final/entry-expired/artifact-expired-claim';
      const deleteMany = vi.fn();
      const upsert = vi.fn().mockResolvedValue({ id: 'job-copy' });
      const tx = staleUploadTransaction(now, vi.fn(), upsert, {
        storageKey: 'artifacts/staging/entry-expired/artifact-expired',
        uploadExpiresAt: expiresAt,
        createdAt: new Date(now.getTime() - 60_000),
        artifactUploadSession: {
          findMany: vi.fn().mockResolvedValue([
            {
              storageKey: 'artifacts/staging/entry-expired/artifact-expired',
              expiresAt,
              credentialExpiresAt: expiresAt,
              completionFinalKey: finalKey,
              completionClaimedAt: claimedAt,
            },
          ]),
          deleteMany,
        },
      });
      const prisma = staleArtifactPrisma(tx, {
        id: 'artifact-expired',
        entryId: 'entry-expired',
      });

      await expect(expireStaleArtifactUploads(prisma, { now })).resolves.toBe(0);
      expect(deleteMany).not.toHaveBeenCalled();
      const finalJob = upsert.mock.calls
        .map(([call]) => call)
        .find((call) => call.where.storageKey === finalKey);
      expect(finalJob.create.nextAttemptAt).toEqual(
        new Date(claimedAt.getTime() + artifactCompletionClaimLeaseMs() + 5 * 60_000)
      );
    });
  });

  describe('cleanupFailedArtifacts', () => {
    it('retains failed artifacts for seven days, then deletes them in a bounded pass', async () => {
      const failedAt = new Date('2026-07-01T12:00:00.000Z');
      const candidate = { id: 'artifact-failed', entryId: 'entry-failed' };
      const artifact = {
        ...candidate,
        uploadState: 'failed',
        failedAt,
      };
      const findMany = vi.fn().mockImplementation(async ({ where }: any) => {
        return where.failedAt.lte >= failedAt ? [candidate] : [];
      });
      const remove = vi.fn().mockResolvedValue(artifact);
      const tx = {
        $queryRaw: vi.fn().mockResolvedValue([{ id: 'entry-failed' }]),
        practiceEntry: {
          findUnique: vi.fn().mockResolvedValue({ id: 'entry-failed', deletedAt: null }),
          update: vi.fn().mockResolvedValue({}),
        },
        artifact: {
          findUnique: vi.fn().mockResolvedValue(artifact),
          delete: remove,
        },
      };
      const prisma = {
        artifact: { findMany },
        $transaction: vi.fn(async (operation: (client: typeof tx) => unknown) => operation(tx)),
      } as any;

      await expect(
        cleanupFailedArtifacts(prisma, {
          now: new Date('2026-07-08T11:59:59.999Z'),
        })
      ).resolves.toBe(0);
      expect(remove).not.toHaveBeenCalled();

      await expect(
        cleanupFailedArtifacts(prisma, {
          now: new Date('2026-07-08T12:00:00.000Z'),
        })
      ).resolves.toBe(1);
      expect(remove).toHaveBeenCalledWith({ where: { id: 'artifact-failed' } });
    });
  });

  // ── cascadeDeleteEntry ──
  describe('cascadeDeleteEntry', () => {
    it('rejects an entry already tombstoned by a concurrent deletion', async () => {
      const artifactFindMany = vi.fn();
      const mockPrisma = {
        $transaction: vi.fn(async (fn: (tx: any) => unknown) =>
          fn({
            $queryRaw: vi.fn().mockResolvedValue([{ id: 'entry-deleted' }]),
            practiceEntry: {
              findUnique: vi.fn().mockResolvedValue({ id: 'entry-deleted', deletedAt: new Date() }),
              update: vi.fn(),
            },
            artifact: { findMany: artifactFindMany },
          })
        ),
      } as any;

      await expect(cascadeDeleteEntry(mockPrisma, 'entry-deleted')).rejects.toMatchObject({
        statusCode: 410,
        code: 'ENTRY_DELETED',
      });
      expect(artifactFindMany).not.toHaveBeenCalled();
    });

    it('throws ENTRY_NOT_FOUND when Prisma returns P2025 (entry does not exist)', async () => {
      const p2025Error = Object.assign(new Error('Record not found'), {
        code: 'P2025',
        clientVersion: '5.0.0',
      });

      const { tx: mockTx } = emptyCascadeTransaction(
        'nonexistent-entry',
        vi.fn().mockRejectedValue(p2025Error)
      );
      const mockPrisma = {
        $transaction: vi.fn(async (operation: (client: typeof mockTx) => unknown) =>
          operation(mockTx)
        ),
      } as any;

      try {
        await cascadeDeleteEntry(mockPrisma, 'nonexistent-entry');
        expect.unreachable('should have thrown');
      } catch (e) {
        const err = e as ApiError;
        expect(err).toBeInstanceOf(ApiError);
        expect(err.statusCode).toBe(404);
        expect(err.code).toBe('ENTRY_NOT_FOUND');
      }
    });

    it('rethrows non-P2025 Prisma errors', async () => {
      const dbError = new Error('Connection refused');

      const mockPrisma = {
        $transaction: vi.fn(async () => {
          throw dbError;
        }),
      } as any;

      await expect(cascadeDeleteEntry(mockPrisma, 'some-entry')).rejects.toThrow(
        'Connection refused'
      );
    });

    it('returns storage keys after successful cascade delete', async () => {
      const mockTx = {
        $queryRaw: vi.fn().mockResolvedValue([{ id: 'entry-1' }]),
        artifact: {
          findMany: vi.fn().mockResolvedValue([
            { id: 'art-1', storageKey: 'artifacts/entry-1/art-1' },
            { id: 'art-2', storageKey: 'artifacts/entry-1/art-2' },
            { id: 'art-3', storageKey: null }, // artifact without storage key
          ]),
          deleteMany: vi.fn().mockResolvedValue({ count: 3 }),
        },
        feedback: {
          findMany: vi.fn().mockResolvedValue([{ id: 'fb-1' }, { id: 'fb-2' }]),
          deleteMany: vi.fn().mockResolvedValue({ count: 2 }),
        },
        marker: {
          deleteMany: vi.fn().mockResolvedValue({ count: 5 }),
        },
        practiceEntry: {
          findUnique: vi.fn().mockResolvedValue({ id: 'entry-1' }),
          delete: vi.fn().mockResolvedValue({ id: 'entry-1' }),
        },
        storageDeletionJob: { createMany: vi.fn().mockResolvedValue({ count: 2 }) },
        deletedEntryTombstone: { upsert: vi.fn().mockResolvedValue({ id: 'entry-1' }) },
      };

      const mockPrisma = {
        $transaction: vi.fn(async (fn: (tx: any) => any) => fn(mockTx)),
      } as any;

      const keys = await cascadeDeleteEntry(mockPrisma, 'entry-1');

      // Should return only non-null storage keys
      expect(keys).toEqual(['artifacts/entry-1/art-1', 'artifacts/entry-1/art-2']);
      // Verify cascading deletes were called
      expect(mockTx.marker.deleteMany).toHaveBeenCalled();
      expect(mockTx.feedback.deleteMany).toHaveBeenCalled();
      expect(mockTx.artifact.deleteMany).toHaveBeenCalled();
      expect(mockTx.storageDeletionJob.createMany).toHaveBeenCalledWith({
        data: [
          expect.objectContaining({ entryId: 'entry-1', storageKey: 'artifacts/entry-1/art-1' }),
          expect.objectContaining({ entryId: 'entry-1', storageKey: 'artifacts/entry-1/art-2' }),
        ],
        skipDuplicates: true,
      });
      expect(mockTx.deletedEntryTombstone.upsert).toHaveBeenCalledWith({
        where: { id: 'entry-1' },
        create: { id: 'entry-1' },
        update: {},
      });
      expect(mockTx.practiceEntry.delete).toHaveBeenCalledWith({ where: { id: 'entry-1' } });
    });

    it('deduplicates staging cleanup and keeps late PUT and copy grace periods', async () => {
      const expiresAt = new Date(Date.now() + 4 * 60_000);
      const credentialExpiresAt = new Date(Date.now() + 2 * 60_000);
      const expectedCleanupAt = new Date(expiresAt.getTime() + 5 * 60_000);
      const mockTx = {
        $queryRaw: vi.fn().mockResolvedValue([{ id: 'entry-with-active-upload' }]),
        artifact: {
          findMany: vi.fn().mockResolvedValue([
            {
              id: 'artifact-uploading',
              storageKey: 'artifacts/staging/entry/artifact',
              uploadSessions: [
                {
                  storageKey: 'artifacts/staging/entry/artifact',
                  completionFinalKey: 'artifacts/final/entry/artifact-session',
                  completionClaimedAt: null,
                  credentialExpiresAt,
                  completedAt: null,
                  expiresAt,
                },
              ],
            },
          ]),
          deleteMany: vi.fn().mockResolvedValue({ count: 1 }),
        },
        feedback: {
          findMany: vi.fn().mockResolvedValue([]),
          deleteMany: vi.fn(),
        },
        marker: { deleteMany: vi.fn() },
        practiceEntry: {
          findUnique: vi.fn().mockResolvedValue({
            id: 'entry-with-active-upload',
            deletedAt: null,
          }),
          delete: vi.fn().mockResolvedValue({ id: 'entry-with-active-upload' }),
        },
        storageDeletionJob: { createMany: vi.fn().mockResolvedValue({ count: 2 }) },
        deletedEntryTombstone: { upsert: vi.fn().mockResolvedValue({}) },
      };
      const prisma = {
        $transaction: vi.fn(async (operation: (tx: typeof mockTx) => unknown) => operation(mockTx)),
      } as any;

      await expect(cascadeDeleteEntry(prisma, 'entry-with-active-upload')).resolves.toEqual([
        'artifacts/staging/entry/artifact',
        'artifacts/final/entry/artifact-session',
      ]);
      expect(mockTx.storageDeletionJob.createMany).toHaveBeenCalledWith({
        data: [
          {
            entryId: 'entry-with-active-upload',
            storageKey: 'artifacts/staging/entry/artifact',
            nextAttemptAt: expectedCleanupAt,
          },
          {
            entryId: 'entry-with-active-upload',
            storageKey: 'artifacts/final/entry/artifact-session',
            nextAttemptAt: expectedCleanupAt,
          },
        ],
        skipDuplicates: true,
      });
    });

    it('handles entry with no artifacts', async () => {
      const { artifactDelete, tx: mockTx } = emptyCascadeTransaction('entry-no-arts');

      const mockPrisma = {
        $transaction: vi.fn(async (fn: (tx: any) => any) => fn(mockTx)),
      } as any;

      const keys = await cascadeDeleteEntry(mockPrisma, 'entry-no-arts');
      expect(keys).toEqual([]);
      // Should not call artifact deleteMany since no artifacts
      expect(artifactDelete).not.toHaveBeenCalled();
    });

    it('handles entry with artifacts that have feedback and markers', async () => {
      const feedbackCallCount = { count: 0 };
      const mockTx = {
        $queryRaw: vi.fn().mockResolvedValue([{ id: 'entry-with-fb' }]),
        artifact: {
          findMany: vi.fn().mockResolvedValue([{ id: 'art-1', storageKey: 'key-1' }]),
          deleteMany: vi.fn().mockResolvedValue({ count: 1 }),
        },
        feedback: {
          findMany: vi.fn().mockImplementation(({ where }: any) => {
            feedbackCallCount.count++;
            // First call for artifact feedback, second for entry feedback
            if (where.targetType === 'artifact') {
              return Promise.resolve([{ id: 'fb-art-1' }]);
            }
            return Promise.resolve([{ id: 'fb-entry-1' }]);
          }),
          deleteMany: vi.fn().mockResolvedValue({ count: 1 }),
        },
        marker: {
          deleteMany: vi.fn().mockResolvedValue({ count: 2 }),
        },
        practiceEntry: {
          findUnique: vi.fn().mockResolvedValue({ id: 'entry-with-fb' }),
          delete: vi.fn().mockResolvedValue({ id: 'entry-with-fb' }),
        },
        storageDeletionJob: { createMany: vi.fn().mockResolvedValue({ count: 1 }) },
        deletedEntryTombstone: {
          upsert: vi.fn().mockResolvedValue({ id: 'entry-with-fb' }),
        },
      };

      const mockPrisma = {
        $transaction: vi.fn(async (fn: (tx: any) => any) => fn(mockTx)),
      } as any;

      const keys = await cascadeDeleteEntry(mockPrisma, 'entry-with-fb');
      expect(keys).toEqual(['key-1']);
      // Feedback findMany should be called twice (artifact + entry)
      expect(mockTx.feedback.findMany).toHaveBeenCalledTimes(2);
      // Markers should be deleted for both artifact and entry feedback
      expect(mockTx.marker.deleteMany).toHaveBeenCalledTimes(2);
    });
  });
});
