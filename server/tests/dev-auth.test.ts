import request from 'supertest';
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import { PrismaClient } from '@prisma/client';

describe('dev auth disabled', () => {
  let app: any;
  let prisma: PrismaClient;
  let originalAuthMode: string | undefined;
  let originalOidcIssuer: string | undefined;
  let originalCorsOrigins: string | undefined;

  beforeAll(async () => {
    originalAuthMode = process.env.AUTH_MODE;
    originalOidcIssuer = process.env.OIDC_ISSUER;
    originalCorsOrigins = process.env.CORS_ORIGINS;
    process.env.AUTH_MODE = 'prod';
    process.env.OIDC_ISSUER = 'https://test.example.com';
    process.env.CORS_ORIGINS = 'https://test.example.com';

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
    process.env.OIDC_ISSUER = originalOidcIssuer;
    process.env.CORS_ORIGINS = originalCorsOrigins;
  });

  it('returns 404 for dev login', async () => {
    const res = await request(app.server).get('/dev/login');
    expect(res.status).toBe(404);
  });

  it('returns 404 for dev issue', async () => {
    const res = await request(app.server).post('/dev/issue').send({ role: 'student' });
    expect(res.status).toBe(404);
  });
});
