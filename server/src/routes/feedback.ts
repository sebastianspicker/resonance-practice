import type { PrismaClient } from '@prisma/client';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { registerFeedbackPostRoute } from './feedback/registration.js';

export function registerFeedbackRoutes(
  app: FastifyInstance,
  prisma: PrismaClient,
  requireAuth: (request: FastifyRequest) => Promise<void>
) {
  registerFeedbackPostRoute(app, prisma, requireAuth);
}
