import { DeleteObjectCommand, S3Client } from '@aws-sdk/client-s3';
import { describe, expect, it } from 'vitest';
import { retryStorageDeletionJobs } from '../src/modules/media/application/cleanup/storageDeletionRetry.js';
import { installBasicSuite, prisma, s3Mock } from './support/testUtils.js';

const logger = { error: () => undefined };

describe('storage deletion job claims', () => {
  installBasicSuite({ resetS3: true });

  it('lets only one replica process a claimed job', async () => {
    await prisma.storageDeletionJob.create({
      data: { entryId: 'entry-gone', storageKey: 'objects/delete-once' },
    });
    let releaseDelete!: () => void;
    let markStarted!: () => void;
    const started = new Promise<void>((resolve) => {
      markStarted = resolve;
    });
    const release = new Promise<void>((resolve) => {
      releaseDelete = resolve;
    });
    s3Mock.on(DeleteObjectCommand).callsFake(async () => {
      markStarted();
      await release;
      return {};
    });

    const s3 = new S3Client({});
    const firstWorker = retryStorageDeletionJobs(prisma, s3, logger, { limit: 1 });
    await started;
    await expect(retryStorageDeletionJobs(prisma, s3, logger, { limit: 1 })).resolves.toBe(0);
    releaseDelete();
    await expect(firstWorker).resolves.toBe(1);
    expect(s3Mock.commandCalls(DeleteObjectCommand)).toHaveLength(1);
    await expect(prisma.storageDeletionJob.count()).resolves.toBe(0);
  });
});
