import { PrismaClient } from '@prisma/client';
import { config } from './config.js';
import { createS3Client, ensureBucket } from './storage.js';
import { buildServer } from './server.js';

const prisma = new PrismaClient();
const s3 = createS3Client();

await ensureBucket(s3);
const app = buildServer(prisma, s3);

for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, async () => {
    app.log.info({ signal }, 'Received signal, shutting down gracefully');
    await app.close();
    await prisma.$disconnect();
    process.exit(0);
  });
}

process.on('unhandledRejection', (err) => {
  app.log.error(err, 'Unhandled rejection');
  process.exit(1);
});

app
  .listen({ port: config.port, host: '0.0.0.0' })
  .then(() => {
    app.log.info(`Server running on port ${config.port}`);
  })
  .catch((err) => {
    app.log.error(err);
    process.exit(1);
  });
