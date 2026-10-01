/** Unit coverage for background maintenance coalescing, ordering, and failure isolation. */
import type { S3Client } from '@aws-sdk/client-s3';
import type { PrismaClient } from '@prisma/client';
import type { FastifyBaseLogger } from 'fastify';
import { describe, expect, it, vi } from 'vitest';
import {
  createMaintenanceRunner,
  maintenanceJobs,
  type MaintenanceJob,
} from '../src/app/maintenance.js';

function fakeLog() {
  return { error: vi.fn() } as unknown as FastifyBaseLogger & {
    error: ReturnType<typeof vi.fn>;
  };
}

describe('maintenance runner', () => {
  it('runs the production jobs in their established order', () => {
    const jobs = maintenanceJobs({} as PrismaClient, {} as S3Client, fakeLog());
    expect(jobs.map((job) => job.failureMessage)).toEqual([
      'Failed to expire stale artifact uploads',
      'Failed to prune retained failed artifacts',
      'Failed to prune completed artifact upload sessions',
      'Failed to process queued S3 deletions',
      'Failed to expire sync command receipts',
      'Failed to expire revoked refresh tokens',
    ]);
  });

  it('coalesces concurrent runs into one pass and starts a new pass afterwards', async () => {
    let release: () => void = () => undefined;
    const slow = vi.fn(() => new Promise<void>((resolve) => (release = resolve)));
    const after = vi.fn(async () => undefined);
    const runner = createMaintenanceRunner(
      [
        { failureMessage: 'slow failed', run: slow },
        { failureMessage: 'after failed', run: after },
      ],
      fakeLog()
    );

    const first = runner.run();
    const second = runner.run();
    expect(second).toBe(first);
    expect(runner.inFlight()).toBe(first);
    expect(slow).toHaveBeenCalledTimes(1);

    release();
    await Promise.all([first, second]);
    await Promise.resolve();
    expect(after).toHaveBeenCalledTimes(1);
    expect(runner.inFlight()).toBeNull();

    const third = runner.run();
    expect(third).not.toBe(first);
    release();
    await third;
    expect(slow).toHaveBeenCalledTimes(2);
    expect(after).toHaveBeenCalledTimes(2);
  });

  it('logs a failing job and still runs the remaining jobs in order', async () => {
    const calls: string[] = [];
    const failure = new Error('storage offline');
    const jobs: MaintenanceJob[] = [
      { failureMessage: 'first failed', run: async () => calls.push('first') },
      {
        failureMessage: 'second failed',
        run: async () => {
          calls.push('second');
          throw failure;
        },
      },
      { failureMessage: 'third failed', run: async () => calls.push('third') },
    ];
    const log = fakeLog();

    await expect(createMaintenanceRunner(jobs, log).run()).resolves.toBeUndefined();
    expect(calls).toEqual(['first', 'second', 'third']);
    expect(log.error).toHaveBeenCalledTimes(1);
    expect(log.error).toHaveBeenCalledWith({ err: failure }, 'second failed');
  });
});
