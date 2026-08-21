/** Entry-route facade with stable public registration and feedback exports. */
import type { PrismaClient } from '@prisma/client';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { registerCaptureMarkerRoute } from './entries/captureMarkers.js';
import { registerEntryCrudRoutes } from './entries/crud.js';
import { registerEntryLifecycleRoutes } from './entries/lifecycle.js';

export { readEntryFeedback } from './entries/lifecycle.js';

export function registerEntryRoutes(
  app: FastifyInstance,
  prisma: PrismaClient,
  requireAuth: (request: FastifyRequest) => Promise<void>
) {
  registerEntryCrudRoutes(app, prisma, requireAuth);
  registerCaptureMarkerRoute(app, prisma, requireAuth);
  registerEntryLifecycleRoutes(app, prisma, requireAuth);
}
