import { describe, expect, it, vi, beforeEach } from 'vitest';
import { S3Client, DeleteObjectCommand } from '@aws-sdk/client-s3';
import { mockClient } from 'aws-sdk-client-mock';
import { cascadeDeleteEntry, cleanupS3Objects } from '../src/services/entryCascade.js';
import { ApiError } from '../src/errors.js';

/**
 * Tests for entryCascade.ts:
 * - cleanupS3Objects: S3 deletion failure logs error but does not throw
 * - cleanupS3Objects: successful deletion
 * - cleanupS3Objects: empty storage keys (no-op)
 * - cascadeDeleteEntry: entry not found (P2025)
 * - cascadeDeleteEntry: successful cascade with artifacts/feedback/markers
 */

const s3Mock = mockClient(S3Client);

describe('entryCascade', () => {
  beforeEach(() => {
    s3Mock.reset();
  });

  // ── cleanupS3Objects ──
  describe('cleanupS3Objects', () => {
    it('successfully deletes S3 objects for given storage keys', async () => {
      s3Mock.on(DeleteObjectCommand).resolves({});
      const s3 = new S3Client({});
      const logger = { error: vi.fn() };

      await cleanupS3Objects(s3, ['key1', 'key2', 'key3'], logger);

      expect(s3Mock.commandCalls(DeleteObjectCommand).length).toBe(3);
      expect(logger.error).not.toHaveBeenCalled();
    });

    it('does nothing when storage keys array is empty', async () => {
      const s3 = new S3Client({});
      const logger = { error: vi.fn() };

      await cleanupS3Objects(s3, [], logger);

      expect(s3Mock.commandCalls(DeleteObjectCommand).length).toBe(0);
      expect(logger.error).not.toHaveBeenCalled();
    });

    it('logs error but does not throw when S3 deletion fails', async () => {
      s3Mock.on(DeleteObjectCommand).rejects(new Error('S3 network error'));
      const s3 = new S3Client({});
      const logger = { error: vi.fn() };

      // Should NOT throw
      await cleanupS3Objects(s3, ['failing-key'], logger);

      expect(logger.error).toHaveBeenCalledTimes(1);
      expect(logger.error).toHaveBeenCalledWith(
        expect.objectContaining({ err: expect.any(Error), storageKey: 'failing-key' }),
        'Failed to delete S3 object after entry deletion'
      );
    });

    it('logs errors for individual failures but continues processing remaining keys', async () => {
      // First call fails, second succeeds, third fails
      s3Mock
        .on(DeleteObjectCommand)
        .rejectsOnce(new Error('fail-1'))
        .resolvesOnce({})
        .rejectsOnce(new Error('fail-3'));
      const s3 = new S3Client({});
      const logger = { error: vi.fn() };

      await cleanupS3Objects(s3, ['key-fail-1', 'key-ok', 'key-fail-3'], logger);

      expect(s3Mock.commandCalls(DeleteObjectCommand).length).toBe(3);
      expect(logger.error).toHaveBeenCalledTimes(2);
    });
  });

  // ── cascadeDeleteEntry ──
  describe('cascadeDeleteEntry', () => {
    it('throws ENTRY_NOT_FOUND when Prisma returns P2025 (entry does not exist)', async () => {
      const p2025Error = Object.assign(new Error('Record not found'), {
        code: 'P2025',
        clientVersion: '5.0.0',
      });

      const mockPrisma = {
        $transaction: vi.fn(async (fn: (tx: any) => any) => {
          const mockTx = {
            artifact: {
              findMany: vi.fn().mockResolvedValue([]),
              deleteMany: vi.fn(),
            },
            feedback: {
              findMany: vi.fn().mockResolvedValue([]),
              deleteMany: vi.fn(),
            },
            marker: {
              deleteMany: vi.fn(),
            },
            practiceEntry: {
              update: vi.fn().mockRejectedValue(p2025Error),
            },
          };
          return fn(mockTx);
        }),
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
          update: vi.fn().mockResolvedValue({ id: 'entry-1', deletedAt: expect.any(Date) }),
        },
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
      expect(mockTx.practiceEntry.update).toHaveBeenCalledWith({
        where: { id: 'entry-1' },
        data: { deletedAt: expect.any(Date) },
      });
    });

    it('handles entry with no artifacts', async () => {
      const mockTx = {
        artifact: {
          findMany: vi.fn().mockResolvedValue([]),
          deleteMany: vi.fn(),
        },
        feedback: {
          findMany: vi.fn().mockResolvedValue([]),
          deleteMany: vi.fn(),
        },
        marker: {
          deleteMany: vi.fn(),
        },
        practiceEntry: {
          update: vi.fn().mockResolvedValue({ id: 'entry-no-arts', deletedAt: expect.any(Date) }),
        },
      };

      const mockPrisma = {
        $transaction: vi.fn(async (fn: (tx: any) => any) => fn(mockTx)),
      } as any;

      const keys = await cascadeDeleteEntry(mockPrisma, 'entry-no-arts');
      expect(keys).toEqual([]);
      // Should not call artifact deleteMany since no artifacts
      expect(mockTx.artifact.deleteMany).not.toHaveBeenCalled();
    });

    it('handles entry with artifacts that have feedback and markers', async () => {
      const feedbackCallCount = { count: 0 };
      const mockTx = {
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
          update: vi.fn().mockResolvedValue({ id: 'entry-with-fb', deletedAt: expect.any(Date) }),
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
