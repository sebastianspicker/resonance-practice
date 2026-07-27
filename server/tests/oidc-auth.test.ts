/**
 * OIDC auth tests.
 *
 * Verifies:
 * - oidc.ts module functions (unit: codes, state, role/name extraction)
 * - /auth/oidc/login and /auth/oidc/callback return 501 when OIDC is not configured
 * - /auth/session and /auth/refresh remain functional in development mode
 * - Prod auth code isolation from dev auth codes
 */
import request from 'supertest';
import { beforeAll, afterAll, beforeEach, describe, expect, it } from 'vitest';
import {
  app,
  expectDevSessionIssued,
  issueDevSession,
  prisma,
  resetDb,
  seedBasic,
  setupApp,
  teardownApp,
} from './support/testUtils.js';
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

describe('oidc module: prod auth codes', () => {
  beforeEach(async () => {
    await resetDb();
    await seedBasic();
  });

  it('issues and consumes a prod auth code', async () => {
    const code = await issueProdAuthCode(prisma, 'user-123');
    expect(code).toMatch(/^prod_/);
    await expect(consumeProdAuthCode(prisma, code)).resolves.toBe('user-123');
  });

  it('consumes a code only once (single-use)', async () => {
    const code = await issueProdAuthCode(prisma, 'user-123');
    const results = await Promise.all([
      consumeProdAuthCode(prisma, code),
      consumeProdAuthCode(prisma, code),
    ]);
    expect(results.sort()).toEqual([null, 'user-123']);
  });

  it('returns null for an unknown code', async () => {
    await expect(consumeProdAuthCode(prisma, 'prod_doesnotexist')).resolves.toBeNull();
  });
});

describe('oidc module: OIDC state (CSRF)', () => {
  beforeEach(async () => {
    await resetDb();
    await seedBasic();
  });

  it('issues and validates a state token', async () => {
    const state = await issueOidcState(prisma);
    expect(typeof state).toBe('string');
    expect(state.length).toBeGreaterThanOrEqual(16);
    await expect(consumeOidcState(prisma, state)).resolves.toBe(true);
  });

  it('consumes a state only once', async () => {
    const state = await issueOidcState(prisma);
    await expect(consumeOidcState(prisma, state)).resolves.toBe(true);
    await expect(consumeOidcState(prisma, state)).resolves.toBe(false);
  });

  it('rejects an unknown state', async () => {
    await expect(consumeOidcState(prisma, 'unknown-state-xyz')).resolves.toBe(false);
  });
});

describe('oidc module: helpers', () => {
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

describe('OIDC routes: not configured (test env)', () => {
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

describe('auth session/refresh: dev mode (existing behaviour)', () => {
  beforeEach(async () => {
    await resetDb();
    await seedBasic();
  });

  it('POST /auth/session still exchanges a dev code for tokens', async () => {
    const { issue, session } = await issueDevSession('student');
    expectDevSessionIssued(issue, session);
  });

  it('POST /auth/refresh works with a valid refresh token', async () => {
    const { session } = await issueDevSession('student', { includeRedirectUri: false });
    const { refreshToken } = session.body as { refreshToken: string };

    const refreshed = await request(app.server).post('/auth/refresh').send({ refreshToken });
    expect(refreshed.status).toBe(200);
    expect(typeof refreshed.body.accessToken).toBe('string');
  });

  it('POST /auth/session rejects a prod code in dev mode', async () => {
    // Production codes are not consumed in development mode, which preserves mode isolation.
    const prodCode = await issueProdAuthCode(prisma, 'some-user');
    const res = await request(app.server).post('/auth/session').send({ code: prodCode });
    expect(res.status).toBe(401);
    expect(res.body.error?.code).toBe('INVALID_CODE');
  });
});
