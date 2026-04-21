/**
 * OIDC auth tests.
 *
 * Coverage:
 * - oidc.ts module functions (unit: codes, state, role/name extraction)
 * - /auth/oidc/login and /auth/oidc/callback return 501 when OIDC is not configured
 * - /auth/session and /auth/refresh remain functional after removing prod gates
 * - Prod auth code isolation from dev auth codes
 */
import request from 'supertest';
import { beforeAll, afterAll, beforeEach, describe, expect, it } from 'vitest';
import { app, setupApp, teardownApp, resetDb, seedBasic } from './testUtils.js';
import {
  issueProdAuthCode,
  consumeProdAuthCode,
  issueOidcState,
  consumeOidcState,
  ssoUserId,
  roleFromClaims,
  displayNameFromClaims,
  _resetOidcClientForTesting,
} from '../src/oidc.js';

beforeAll(async () => {
  await setupApp();
});

afterAll(async () => {
  await teardownApp();
});

// ── Unit: oidc module functions ──────────────────────────────────────────────

describe('oidc module — prod auth codes', () => {
  it('issues and consumes a prod auth code', () => {
    const code = issueProdAuthCode('user-123');
    expect(code).toMatch(/^prod_/);
    expect(consumeProdAuthCode(code)).toBe('user-123');
  });

  it('consumes a code only once (single-use)', () => {
    const code = issueProdAuthCode('user-123');
    expect(consumeProdAuthCode(code)).toBe('user-123');
    expect(consumeProdAuthCode(code)).toBeNull();
  });

  it('returns null for an unknown code', () => {
    expect(consumeProdAuthCode('prod_doesnotexist')).toBeNull();
  });
});

describe('oidc module — OIDC state (CSRF)', () => {
  it('issues and validates a state token', () => {
    const state = issueOidcState();
    expect(typeof state).toBe('string');
    expect(state.length).toBeGreaterThanOrEqual(16);
    expect(consumeOidcState(state)).toBe(true);
  });

  it('consumes a state only once', () => {
    const state = issueOidcState();
    expect(consumeOidcState(state)).toBe(true);
    expect(consumeOidcState(state)).toBe(false);
  });

  it('rejects an unknown state', () => {
    expect(consumeOidcState('unknown-state-xyz')).toBe(false);
  });
});

describe('oidc module — helpers', () => {
  it('ssoUserId prefixes with sso:', () => {
    expect(ssoUserId('abc123')).toBe('sso:abc123');
  });

  it('roleFromClaims defaults to student when oidcConfig is null', () => {
    // oidcConfig is null in test env (no OIDC env vars set)
    expect(roleFromClaims({ role: 'teacher' })).toBe('student');
  });

  describe('displayNameFromClaims', () => {
    it('uses name claim first', () => {
      expect(
        displayNameFromClaims({ name: 'Alice Smith', preferred_username: 'alice', sub: 's1' })
      ).toBe('Alice Smith');
    });

    it('falls back to preferred_username', () => {
      expect(displayNameFromClaims({ preferred_username: 'alice', sub: 's1' })).toBe('alice');
    });

    it('falls back to email', () => {
      expect(displayNameFromClaims({ email: 'alice@uni.de', sub: 's1' })).toBe('alice@uni.de');
    });

    it('falls back to sub', () => {
      expect(displayNameFromClaims({ sub: 's1' })).toBe('s1');
    });

    it('returns Unknown User when all claims are empty', () => {
      expect(displayNameFromClaims({})).toBe('Unknown User');
    });
  });
});

// ── Integration: OIDC routes return 501 when not configured ──────────────────

describe('OIDC routes — not configured (test env)', () => {
  it('GET /auth/oidc/login returns 501 AUTH_NOT_CONFIGURED', async () => {
    const res = await request(app.server).get('/auth/oidc/login');
    expect(res.status).toBe(501);
    expect(res.body.error?.code).toBe('AUTH_NOT_CONFIGURED');
  });

  it('GET /auth/oidc/callback returns 501 AUTH_NOT_CONFIGURED', async () => {
    const res = await request(app.server).get('/auth/oidc/callback?code=x&state=y');
    expect(res.status).toBe(501);
    expect(res.body.error?.code).toBe('AUTH_NOT_CONFIGURED');
  });
});

// ── Integration: session/refresh still work in dev mode ─────────────────────

describe('auth session/refresh — dev mode (existing behaviour)', () => {
  beforeEach(async () => {
    await resetDb();
    await seedBasic();
  });

  it('POST /auth/session still exchanges a dev code for tokens', async () => {
    const issue = await request(app.server).post('/dev/issue').send({ role: 'student' });
    expect(issue.status).toBe(200);

    const session = await request(app.server)
      .post('/auth/session')
      .send({ code: issue.body.code, redirectUri: 'resonance://auth-callback' });
    expect(session.status).toBe(201);
    expect(typeof session.body.accessToken).toBe('string');
  });

  it('POST /auth/refresh works with a valid refresh token', async () => {
    const issue = await request(app.server).post('/dev/issue').send({ role: 'student' });
    const session = await request(app.server).post('/auth/session').send({ code: issue.body.code });
    const { refreshToken } = session.body as { refreshToken: string };

    const refreshed = await request(app.server).post('/auth/refresh').send({ refreshToken });
    expect(refreshed.status).toBe(200);
    expect(typeof refreshed.body.accessToken).toBe('string');
  });

  it('POST /auth/session rejects a prod code in dev mode', async () => {
    // Prod codes are not consumed in dev mode — ensures mode isolation.
    const prodCode = issueProdAuthCode('some-user');
    const res = await request(app.server).post('/auth/session').send({ code: prodCode });
    expect(res.status).toBe(401);
    expect(res.body.error?.code).toBe('INVALID_CODE');
  });
});
