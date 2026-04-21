import request from 'supertest';
import { describe, expect, it, vi } from 'vitest';
import { PrismaClient } from '@prisma/client';

function buildOriginRequest(app: any, origin?: string) {
  const req = request(app.server).options('/health');
  if (origin) {
    req.set('Origin', origin);
    req.set('Access-Control-Request-Method', 'GET');
  }
  return req;
}

describe('cors', () => {
  it('fails closed when CORS_ORIGINS is empty', async () => {
    process.env.CORS_ORIGINS = '';
    vi.resetModules();
    const { buildServer } = await import('../src/server.js');
    const prisma = new PrismaClient();
    const app = buildServer(prisma, {} as any);
    await app.ready();

    const res = await buildOriginRequest(app, 'https://example.com');
    expect(res.status).toBe(404);
    expect(res.headers['access-control-allow-origin']).toBeUndefined();

    await app.close();
    await prisma.$disconnect();
  });

  it('enforces allowlist when CORS_ORIGINS is set', async () => {
    process.env.CORS_ORIGINS = 'https://allowed.example, https://second.example';
    vi.resetModules();
    const { buildServer } = await import('../src/server.js');
    const prisma = new PrismaClient();
    const app = buildServer(prisma, {} as any);
    await app.ready();

    const allowed = await buildOriginRequest(app, 'https://allowed.example');
    expect(allowed.status).toBe(204);
    expect(allowed.headers['access-control-allow-origin']).toBe('https://allowed.example');

    const blocked = await buildOriginRequest(app, 'https://blocked.example');
    expect(blocked.status).toBe(204);
    expect(blocked.headers['access-control-allow-origin']).toBeUndefined();

    await app.close();
    await prisma.$disconnect();
  });
});
