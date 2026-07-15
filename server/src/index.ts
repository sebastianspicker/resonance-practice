import { PrismaClient } from '@prisma/client';
import { config } from './config.js';
import { expireStaleArtifactUploads, retryStorageDeletionJobs } from './services/entryCascade.js';
import { settlesWithin, withDeadline } from './services/deadline.js';
import { createS3Client, ensureBucket } from './storage.js';
import { buildServer } from './server.js';

const prisma = new PrismaClient();
const s3 = createS3Client();
const STORAGE_CLEANUP_INTERVAL_MS = 60_000;
const SHUTDOWN_GRACE_MS = 5_000;

const app = buildServer(prisma, s3);

let activeStorageCleanup: Promise<void> | null = null;
function retryStorageCleanupSafely(): Promise<void> {
  if (activeStorageCleanup) return activeStorageCleanup;
  const cleanup = (async () => {
    try {
      await expireStaleArtifactUploads(prisma);
    } catch (err) {
      app.log.error({ err }, 'Failed to expire stale artifact uploads');
    }
    try {
      await retryStorageDeletionJobs(prisma, s3, app.log);
    } catch (err) {
      app.log.error({ err }, 'Failed to process queued S3 deletions');
    }
  })();
  activeStorageCleanup = cleanup;
  void cleanup.finally(() => {
    if (activeStorageCleanup === cleanup) activeStorageCleanup = null;
  });
  return cleanup;
}

let storageCleanupTimer: ReturnType<typeof setInterval> | null = null;
let shuttingDown = false;

async function waitForShutdownStep(promise: Promise<unknown>, label: string): Promise<void> {
  try {
    if (!(await settlesWithin(promise, SHUTDOWN_GRACE_MS, label))) {
      app.log.warn({ label }, 'Shutdown step exceeded its grace period');
    }
  } catch (err) {
    app.log.error({ err, label }, 'Shutdown step failed');
  }
}

for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, async () => {
    if (shuttingDown) return;
    shuttingDown = true;
    app.log.info({ signal }, 'Received signal, shutting down gracefully');
    if (storageCleanupTimer) clearInterval(storageCleanupTimer);
    await waitForShutdownStep(app.close(), 'HTTP server shutdown');
    if (activeStorageCleanup) {
      await waitForShutdownStep(activeStorageCleanup, 'storage cleanup shutdown');
    }
    await waitForShutdownStep(prisma.$disconnect(), 'PostgreSQL disconnect');
    process.exit(0);
  });
}

process.on('unhandledRejection', (err) => {
  app.log.error(err, 'Unhandled rejection');
  process.exit(1);
});

try {
  await withDeadline(
    () => prisma.$connect(),
    config.dependencyTimeoutMs,
    'PostgreSQL startup connection'
  );
  await ensureBucket(s3);
  await app.listen({ port: config.port, host: '0.0.0.0' });
  app.log.info(`Server running on port ${config.port}`);
  storageCleanupTimer = setInterval(() => {
    void retryStorageCleanupSafely();
  }, STORAGE_CLEANUP_INTERVAL_MS);
  storageCleanupTimer.unref();
  void retryStorageCleanupSafely();
} catch (err) {
  app.log.error(err);
  await waitForShutdownStep(prisma.$disconnect(), 'PostgreSQL disconnect');
  process.exit(1);
}
