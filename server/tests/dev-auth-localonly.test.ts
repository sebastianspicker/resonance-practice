import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import { PrismaClient } from '@prisma/client';

describe('dev auth localhost restriction', () => {
  let app: any;
  let prisma: PrismaClient;
  let originalAuthMode: string | undefined;

  beforeAll(async () => {
    originalAuthMode = process.env.AUTH_MODE;
    process.env.AUTH_MODE = 'dev';

    vi.resetModules();
    const { buildServer } = await import('../src/server.js');

    prisma = new PrismaClient();
    app = buildServer(prisma, {} as any);
    await app.ready();
  });

  afterAll(async () => {
    await app.close();
    await prisma.$disconnect();
    process.env.AUTH_MODE = originalAuthMode;
  });

  it('allows localhost for dev auth routes', async () => {
    const res = await app.inject({
      method: 'GET',
      url: '/dev/login',
      remoteAddress: '127.0.0.1',
    });
    expect(res.statusCode).toBe(200);
  });

  it('blocks non-local addresses for dev auth routes', async () => {
    const res = await app.inject({
      method: 'GET',
      url: '/dev/login',
      remoteAddress: '10.22.33.44',
    });
    expect(res.statusCode).toBe(403);
    expect(res.json().error?.code).toBe('DEV_AUTH_LOCAL_ONLY');
  });
});
