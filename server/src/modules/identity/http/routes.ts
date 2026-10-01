/** HTTP authentication route registration facade. */
import type { PrismaClient } from '@prisma/client';
import type { FastifyInstance } from 'fastify';
import { type RequireAuth } from '../../../platform/http/authentication.js';
import { registerDevLoginRoutes } from './auth/devLoginRoutes.js';
import { registerOidcRoutes } from './auth/oidcRoutes.js';
import { registerSessionRoutes } from './auth/sessionRoutes.js';

export function registerAuthRoutes(
  app: FastifyInstance,
  prisma: PrismaClient,
  requireAuth: RequireAuth
) {
  registerDevLoginRoutes(app, prisma);
  registerOidcRoutes(app, prisma);
  registerSessionRoutes(app, prisma, requireAuth);
}
