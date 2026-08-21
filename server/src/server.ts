/** Public Fastify composition root for middleware, routes, and readiness coordination. */
import type { S3Client } from '@aws-sdk/client-s3';
import type { PrismaClient } from '@prisma/client';
import {
  createApiApp,
  createDependencyCheck,
  registerResourceRoutes,
  registerStatusRoutes,
  registerTransport,
} from './serverRuntime.js';

/**
 * Compose the API around injected database and storage clients so production
 * lifecycle code and tests exercise the same middleware and route graph.
 */
export function buildServer(prisma: PrismaClient, s3: S3Client) {
  const app = createApiApp();
  registerTransport(app);
  registerStatusRoutes(app, createDependencyCheck(prisma, s3));
  registerResourceRoutes(app, prisma, s3);
  return app;
}
