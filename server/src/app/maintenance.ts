/** Background maintenance jobs and the coalescing runner that executes them in order. */
import type { S3Client } from '@aws-sdk/client-s3';
import type { PrismaClient } from '@prisma/client';
import type { FastifyBaseLogger } from 'fastify';
import {
  cleanupCompletedArtifactSessions,
  cleanupFailedArtifacts,
} from '../modules/media/application/cleanup/artifactCleanup.js';
import { expireStaleArtifactUploads } from '../modules/media/application/cleanup/staleUploads.js';
import { retryStorageDeletionJobs } from '../modules/media/application/storageDeletion/retry.js';
import { cleanupSyncReceipts } from '../modules/sync/application/receipts.js';
import { cleanupRevokedRefreshTokens } from '../modules/identity/application/maintenance.js';

/** One maintenance step and the message logged when it fails. */
export type MaintenanceJob = { failureMessage: string; run: () => Promise<unknown> };

export type MaintenanceRunner = {
  /** Start a pass, or join the pass already in flight. */
  run(): Promise<void>;
  /** The pass currently in flight, if any. */
  inFlight(): Promise<void> | null;
};

/** The production maintenance jobs, in execution order. */
export function maintenanceJobs(
  prisma: PrismaClient,
  s3: S3Client,
  log: FastifyBaseLogger
): MaintenanceJob[] {
  return [
    {
      failureMessage: 'Failed to expire stale artifact uploads',
      run: () => expireStaleArtifactUploads(prisma),
    },
    {
      failureMessage: 'Failed to prune retained failed artifacts',
      run: () => cleanupFailedArtifacts(prisma),
    },
    {
      failureMessage: 'Failed to prune completed artifact upload sessions',
      run: () => cleanupCompletedArtifactSessions(prisma),
    },
    {
      failureMessage: 'Failed to process queued S3 deletions',
      run: () => retryStorageDeletionJobs(prisma, s3, log),
    },
    {
      failureMessage: 'Failed to expire sync command receipts',
      run: () => cleanupSyncReceipts(prisma),
    },
    {
      failureMessage: 'Failed to expire revoked refresh tokens',
      run: () => cleanupRevokedRefreshTokens(prisma),
    },
  ];
}

/** Coalesce interval and startup passes so slow storage never overlaps itself. */
export function createMaintenanceRunner(
  jobs: readonly MaintenanceJob[],
  log: FastifyBaseLogger
): MaintenanceRunner {
  let active: Promise<void> | null = null;

  return {
    run() {
      if (active) return active;
      const pass = (async () => {
        for (const job of jobs) {
          try {
            await job.run();
          } catch (err) {
            log.error({ err }, job.failureMessage);
          }
        }
      })();
      active = pass;
      void pass.finally(() => {
        if (active === pass) active = null;
      });
      return pass;
    },
    inFlight() {
      return active;
    },
  };
}
