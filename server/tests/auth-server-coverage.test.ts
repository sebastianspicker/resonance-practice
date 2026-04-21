import jwt from 'jsonwebtoken';
import request from 'supertest';
import { beforeAll, afterAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { config } from '../src/config.js';
import { app, setupApp, teardownApp, resetDb, seedBasic, prisma } from './testUtils.js';

/**
 * Tests targeting uncovered branches in:
 * - src/routes/auth.ts (lines 109, 118, 122, 141)
 * - src/server.ts (lines 156, 158-162, 185-186)
 */
describe('auth routes & server branch coverage', () => {
  beforeAll(async () => {
    await setupApp();
  });

  afterAll(async () => {
    await teardownApp();
  });

  beforeEach(async () => {
    await resetDb();
    await seedBasic();
  });

  // ═══════════════════════════════════════════════════════════════════
  // routes/auth.ts — invalid/expired dev auth code (line 118)
  // ═══════════════════════════════════════════════════════════════════

  describe('POST /auth/session — invalid code', () => {
    it('returns 401 INVALID_CODE for a fabricated code', async () => {
      const res = await request(app.server)
        .post('/auth/session')
        .send({ code: 'dev_FAKE_CODE_12345678', redirectUri: 'resonance://auth-callback' });
      expect(res.status).toBe(401);
      expect(res.body.error.code).toBe('INVALID_CODE');
      expect(res.body.error.message).toBe('Invalid or expired auth code');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // routes/auth.ts — user not found during session (line 122)
  // ═══════════════════════════════════════════════════════════════════

  describe('POST /auth/session — user deleted after code issued', () => {
    it('returns 401 USER_NOT_FOUND when user was deleted between code issue and session', async () => {
      // Issue a code for student-1
      const issue = await request(app.server)
        .post('/dev/issue')
        .send({ userId: 'student-1', role: 'student' });
      expect(issue.status).toBe(200);
      const code = issue.body.code;

      // Delete the user before redeeming the code
      await prisma.membership.deleteMany({ where: { userId: 'student-1' } });
      await prisma.refreshToken.deleteMany({ where: { userId: 'student-1' } });
      await prisma.user.delete({ where: { id: 'student-1' } });

      // Now try to exchange the code for tokens
      const res = await request(app.server)
        .post('/auth/session')
        .send({ code, redirectUri: 'resonance://auth-callback' });
      expect(res.status).toBe(401);
      expect(res.body.error.code).toBe('USER_NOT_FOUND');
      expect(res.body.error.message).toBe('User not found');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // routes/auth.ts — /dev/authorize with invalid role (line 63-64)
  // ═══════════════════════════════════════════════════════════════════

  describe('GET /dev/authorize — invalid role', () => {
    it('returns 400 INVALID_ROLE for role=admin', async () => {
      const res = await request(app.server).get('/dev/authorize?role=admin');
      expect(res.status).toBe(400);
      expect(res.body.error.code).toBe('INVALID_ROLE');
    });

    it('returns 400 INVALID_ROLE when role is missing', async () => {
      const res = await request(app.server).get('/dev/authorize');
      expect(res.status).toBe(400);
      expect(res.body.error.code).toBe('INVALID_ROLE');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // routes/auth.ts — /dev/issue with non-existent userId (line 80-81)
  // ═══════════════════════════════════════════════════════════════════

  describe('POST /dev/issue — user not found', () => {
    it('returns 404 USER_NOT_FOUND when userId does not exist', async () => {
      const res = await request(app.server)
        .post('/dev/issue')
        .send({ userId: 'nonexistent-user-id', role: 'student' });
      expect(res.status).toBe(404);
      expect(res.body.error.code).toBe('USER_NOT_FOUND');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // server.ts — requireAuth with valid JWT but missing sub/role (line 185-186)
  // ═══════════════════════════════════════════════════════════════════

  describe('requireAuth — missing sub or role in JWT payload', () => {
    it('returns 401 INVALID_TOKEN when JWT has no sub field', async () => {
      // Sign a JWT with the correct secret but without a sub claim
      const token = jwt.sign({ role: 'student' }, config.jwtSecret, {
        expiresIn: 900,
        issuer: 'resonance-api',
        audience: 'resonance-app',
        algorithm: 'HS256',
      });

      const res = await request(app.server).get('/courses').set('Authorization', `Bearer ${token}`);
      expect(res.status).toBe(401);
      expect(res.body.error.code).toBe('INVALID_TOKEN');
      expect(res.body.error.message).toBe('Invalid token payload');
    });

    it('returns 401 INVALID_TOKEN when JWT has no role field', async () => {
      // Sign a JWT with the correct secret but without a role claim
      const token = jwt.sign({ sub: 'student-1' }, config.jwtSecret, {
        expiresIn: 900,
        issuer: 'resonance-api',
        audience: 'resonance-app',
        algorithm: 'HS256',
      });

      const res = await request(app.server).get('/courses').set('Authorization', `Bearer ${token}`);
      expect(res.status).toBe(401);
      expect(res.body.error.code).toBe('INVALID_TOKEN');
      expect(res.body.error.message).toBe('Invalid token payload');
    });
  });
});

// ═══════════════════════════════════════════════════════════════════
// Production auth mode — lines 109, 141 in routes/auth.ts
// These tests need AUTH_MODE=prod, so they run in a separate server
// ═══════════════════════════════════════════════════════════════════

describe('production auth mode — session and refresh reject invalid input', () => {
  let prodApp: any;
  let prodPrisma: any;
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
    const { PrismaClient } = await import('@prisma/client');

    prodPrisma = new PrismaClient();
    prodApp = buildServer(prodPrisma, {} as any);
    await prodApp.ready();
  });

  afterAll(async () => {
    await prodApp?.close();
    await prodPrisma?.$disconnect();
    process.env.AUTH_MODE = originalAuthMode;
    process.env.OIDC_DISCOVERY_URL = originalOidcDiscoveryUrl;
    process.env.OIDC_CLIENT_ID = originalOidcClientId;
    process.env.OIDC_CLIENT_SECRET = originalOidcClientSecret;
    process.env.OIDC_REDIRECT_URI = originalOidcRedirectUri;
    process.env.CORS_ORIGINS = originalCorsOrigins;
    vi.resetModules();
  });

  it('POST /auth/session rejects a mismatched redirectUri in prod mode', async () => {
    const res = await request(prodApp.server)
      .post('/auth/session')
      .send({ code: 'some-code', redirectUri: 'https://example.com' });
    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe('VALIDATION_ERROR');
    expect(res.body.error.message).toBe('Invalid redirectUri');
  });

  it('POST /auth/refresh rejects an unknown refresh token in prod mode', async () => {
    const res = await request(prodApp.server)
      .post('/auth/refresh')
      .send({ refreshToken: 'some-token-value-that-is-long-enough' });
    expect(res.status).toBe(401);
    expect(res.body.error.code).toBe('INVALID_REFRESH');
  });
});
