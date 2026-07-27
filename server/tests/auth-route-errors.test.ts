// Verifies authentication-route rejection and invalid-session behavior.
import jwt from 'jsonwebtoken';
import { describe, expect, it } from 'vitest';
import { config } from '../src/config.js';
import { app, deleteTestUser, installBasicSuite } from './support/testUtils.js';
import { installProductionAuthTestServer } from './support/productionAuthTestHarness.js';

function signAccessToken(payload: object) {
  return jwt.sign(payload, config.jwtSecret, {
    expiresIn: 900,
    issuer: 'resonance-api',
    audience: 'resonance-app',
    algorithm: 'HS256',
  });
}

async function expectInvalidToken(payload: object) {
  const token = signAccessToken(payload);
  const response = await app.inject({
    method: 'GET',
    url: '/courses',
    headers: { authorization: `Bearer ${token}` },
  });
  const body = response.json();
  expect(response.statusCode).toBe(401);
  expect(body.error.code).toBe('INVALID_TOKEN');
  expect(body.error.message).toBe('Invalid token payload');
}

describe('authentication route errors', () => {
  installBasicSuite();

  // ═══════════════════════════════════════════════════════════════════
  // routes/auth.ts: invalid or expired dev auth code (line 118)
  // ═══════════════════════════════════════════════════════════════════

  describe('POST /auth/session: invalid code', () => {
    it('returns 401 INVALID_CODE for a fabricated code', async () => {
      const res = await app.inject({
        method: 'POST',
        url: '/auth/session',
        payload: { code: 'dev_FAKE_CODE_12345678', redirectUri: 'resonance://auth-callback' },
      });
      const body = res.json();
      expect(res.statusCode).toBe(401);
      expect(body.error.code).toBe('INVALID_CODE');
      expect(body.error.message).toBe('Invalid or expired auth code');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // routes/auth.ts: user not found during session (line 122)
  // ═══════════════════════════════════════════════════════════════════

  describe('POST /auth/session: user deleted after code issued', () => {
    it('returns 401 USER_NOT_FOUND when user was deleted between code issue and session', async () => {
      // Issue a code for student-1
      const issue = await app.inject({
        method: 'POST',
        url: '/dev/issue',
        payload: { userId: 'student-1', role: 'student' },
      });
      expect(issue.statusCode).toBe(200);
      const code = issue.json().code;

      // Delete the user before redeeming the code
      await deleteTestUser('student-1');

      // Now try to exchange the code for tokens
      const res = await app.inject({
        method: 'POST',
        url: '/auth/session',
        payload: { code, redirectUri: 'resonance://auth-callback' },
      });
      const body = res.json();
      expect(res.statusCode).toBe(401);
      expect(body.error.code).toBe('USER_NOT_FOUND');
      expect(body.error.message).toBe('User not found');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // routes/auth.ts: /dev/authorize with invalid role (line 63-64)
  // ═══════════════════════════════════════════════════════════════════

  describe('GET /dev/authorize: invalid role', () => {
    it('returns 400 INVALID_ROLE for role=admin', async () => {
      const res = await app.inject({ method: 'GET', url: '/dev/authorize?role=admin' });
      expect(res.statusCode).toBe(400);
      expect(res.json().error.code).toBe('INVALID_ROLE');
    });

    it('returns 400 INVALID_ROLE when role is missing', async () => {
      const res = await app.inject({ method: 'GET', url: '/dev/authorize' });
      expect(res.statusCode).toBe(400);
      expect(res.json().error.code).toBe('INVALID_ROLE');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // routes/auth.ts: /dev/issue with non-existent userId (line 80-81)
  // ═══════════════════════════════════════════════════════════════════

  describe('POST /dev/issue: user not found', () => {
    it('returns 404 USER_NOT_FOUND when userId does not exist', async () => {
      const res = await app.inject({
        method: 'POST',
        url: '/dev/issue',
        payload: { userId: 'nonexistent-user-id', role: 'student' },
      });
      expect(res.statusCode).toBe(404);
      expect(res.json().error.code).toBe('USER_NOT_FOUND');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // server.ts: requireAuth with valid JWT but missing sub or role (line 185-186)
  // ═══════════════════════════════════════════════════════════════════

  describe('requireAuth: missing sub or role in JWT payload', () => {
    it.each([
      ['sub', { role: 'student' }],
      ['role', { sub: 'student-1' }],
    ])('returns 401 INVALID_TOKEN when JWT has no %s field', async (_claim, payload) => {
      await expectInvalidToken(payload);
    });
  });
});

// ═══════════════════════════════════════════════════════════════════
// Production auth mode: lines 109 and 141 in routes/auth.ts
// These tests need AUTH_MODE=prod, so they run in a separate server
// ═══════════════════════════════════════════════════════════════════

describe('production auth mode: session and refresh reject invalid input', () => {
  const prodServer = installProductionAuthTestServer();

  it('POST /auth/session rejects a mismatched redirectUri in prod mode', async () => {
    const res = await prodServer.app.inject({
      method: 'POST',
      url: '/auth/session',
      payload: { code: 'some-code', redirectUri: 'https://example.com' },
    });
    const body = res.json();
    expect(res.statusCode).toBe(400);
    expect(body.error.code).toBe('VALIDATION_ERROR');
    expect(body.error.message).toBe('Invalid redirectUri');
  });

  it('POST /auth/refresh rejects an unknown refresh token in prod mode', async () => {
    const res = await prodServer.app.inject({
      method: 'POST',
      url: '/auth/refresh',
      payload: { refreshToken: 'some-token-value-that-is-long-enough' },
    });
    expect(res.statusCode).toBe(401);
    expect(res.json().error.code).toBe('INVALID_REFRESH');
  });
});
