// Builds an isolated Fastify server after a test has set its environment variables.
import { PrismaClient } from '@prisma/client';
import { vi } from 'vitest';

export async function buildIsolatedServer() {
  vi.resetModules();
  const { buildServer } = await import('../../src/server.js');
  const prisma = new PrismaClient();
  const app = buildServer(prisma, {} as any);
  await app.ready();
  return { app, prisma };
}
