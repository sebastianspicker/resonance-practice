/** Process entry point that owns dependency lifecycle and schedules background maintenance. */
import { PrismaClient } from '@prisma/client';
import { config } from '../platform/config.js';
import { settlesWithin, withDeadline } from '../platform/deadline.js';
import { createS3Client, ensureBucket } from '../platform/storage/s3.js';
import { buildServer } from '../server.js';
import { createMaintenanceRunner, maintenanceJobs } from './maintenance.js';

const prisma = new PrismaClient();
const s3 = createS3Client();
const STORAGE_CLEANUP_INTERVAL_MS = 60_000;
const SHUTDOWN_GRACE_MS = 5_000;

const app = buildServer(prisma, s3);

const maintenance = createMaintenanceRunner(maintenanceJobs(prisma, s3, app.log), app.log);

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

/** Shutdown is idempotent: both signals may arrive while cleanup is still in flight. */
for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, async () => {
    if (shuttingDown) return;
    shuttingDown = true;
    app.log.info({ signal }, 'Received signal, shutting down gracefully');
    if (storageCleanupTimer) clearInterval(storageCleanupTimer);
    await waitForShutdownStep(app.close(), 'HTTP server shutdown');
    const activeMaintenance = maintenance.inFlight();
    if (activeMaintenance) {
      await waitForShutdownStep(activeMaintenance, 'storage cleanup shutdown');
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
  await app.listen({ port: config.port, host: config.host });
  app.log.info(`Server running at ${config.host}:${config.port}`);
  storageCleanupTimer = setInterval(() => {
    void maintenance.run();
  }, STORAGE_CLEANUP_INTERVAL_MS);
  storageCleanupTimer.unref();
  void maintenance.run();
} catch (err) {
  app.log.error(err);
  await waitForShutdownStep(prisma.$disconnect(), 'PostgreSQL disconnect');
  process.exit(1);
}
