import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import { PrismaClient } from '@prisma/client';

describe('dev auth disabled', () => {
  let app: any;
  let prisma: PrismaClient;
  let originalAuthMode: string | undefined;
  let originalOidcDiscoveryUrl: string | undefined;
  let originalOidcClientId: string | undefined;
  let originalOidcClientSecret: string | undefined;
  let originalOidcRedirectUri: string | undefined;
  let originalCorsOrigins: string | undefined;

  beforeAll(async () => {
    originalAuthMode = process.env.AUTH_MODE;
    originalOidcDiscoveryUrl = process.env.OIDC_DISCOVERY_URL;
    originalOidcClientId = process.env.OIDC_CLIENT_ID;
    originalOidcClientSecret = process.env.OIDC_CLIENT_SECRET;
    originalOidcRedirectUri = process.env.OIDC_REDIRECT_URI;
    originalCorsOrigins = process.env.CORS_ORIGINS;
    process.env.AUTH_MODE = 'prod';
    process.env.OIDC_DISCOVERY_URL = 'https://test.example.com/.well-known/openid-configuration';
    process.env.OIDC_CLIENT_ID = 'test-client';
    process.env.OIDC_CLIENT_SECRET = 'test-secret';
    process.env.OIDC_REDIRECT_URI = 'https://test.example.com/auth/callback';
    process.env.CORS_ORIGINS = 'https://test.example.com';

    vi.resetModules();
    const { buildServer } = await import('../src/server.js');

    prisma = new PrismaClient();
    app = buildServer(prisma, {} as any);
    await app.ready();
  });

  afterAll(async () => {
    await app?.close();
    await prisma?.$disconnect();
    process.env.AUTH_MODE = originalAuthMode;
    process.env.OIDC_DISCOVERY_URL = originalOidcDiscoveryUrl;
    process.env.OIDC_CLIENT_ID = originalOidcClientId;
    process.env.OIDC_CLIENT_SECRET = originalOidcClientSecret;
    process.env.OIDC_REDIRECT_URI = originalOidcRedirectUri;
    process.env.CORS_ORIGINS = originalCorsOrigins;
    vi.resetModules();
  });

  it('returns 404 for dev login', async () => {
    const res = await app.inject({ method: 'GET', url: '/dev/login' });
    expect(res.statusCode).toBe(404);
  });

  it('returns 404 for dev issue', async () => {
    const res = await app.inject({
      method: 'POST',
      url: '/dev/issue',
      payload: { role: 'student' },
    });
    expect(res.statusCode).toBe(404);
  });

  it('redirects app login to the OIDC login route', async () => {
    const res = await app.inject({ method: 'GET', url: '/auth/login' });
    expect(res.statusCode).toBe(302);
    expect(res.headers.location).toBe('/auth/oidc/login');
  });
});
