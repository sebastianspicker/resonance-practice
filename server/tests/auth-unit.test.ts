// Compact token and single-use authentication contracts without Fastify or a database.
import { describe, expect, it, vi } from 'vitest';
import {
  consumeDevAuthCode,
  hashToken,
  issueDevAuthCode,
  signAccessToken,
  signRefreshToken,
  verifyAccessToken,
  verifyRefreshToken,
} from '../src/auth.js';
import { ApiError } from '../src/errors.js';
import { makeUser } from './support/authTestUtils.js';

describe('authentication primitives', () => {
  it('hashes deterministically and round-trips audience-bound access and refresh claims', () => {
    expect(hashToken('token')).toMatch(/^[0-9a-f]{64}$/);
    expect(hashToken('token')).not.toBe(hashToken('other'));

    const user = makeUser({ id: 'user-42', globalRole: 'teacher' });
    const access = verifyAccessToken(signAccessToken(user));
    expect(access).toMatchObject({
      sub: user.id,
      role: 'teacher',
      iss: 'resonance-api',
      aud: 'resonance-app',
    });

    const refresh = verifyRefreshToken(signRefreshToken(user, 'rt_contract'));
    expect(refresh).toMatchObject({
      sub: user.id,
      jti: 'rt_contract',
      iss: 'resonance-api',
      aud: 'resonance-app',
    });
    expect(refresh.role).toBeUndefined();
  });

  it('rejects malformed, tampered, and cross-purpose tokens with generic errors', () => {
    const accessToken = signAccessToken(makeUser());
    expect(() => verifyAccessToken(`${accessToken.slice(0, -5)}XXXXX`)).toThrow(ApiError);
    expect(() => verifyRefreshToken(accessToken)).toThrowError(
      expect.objectContaining({ statusCode: 401 })
    );
    expect(() => verifyRefreshToken('not-a-jwt')).toThrowError(
      expect.objectContaining({ code: 'INVALID_REFRESH' })
    );
  });

  it('makes development codes single-use and rejects them after expiry', () => {
    const code = issueDevAuthCode('user-once');
    expect(consumeDevAuthCode(code)).toBe('user-once');
    expect(consumeDevAuthCode(code)).toBeNull();

    vi.useFakeTimers();
    try {
      const expiring = issueDevAuthCode('user-expired');
      vi.advanceTimersByTime(5 * 60 * 1000 + 1);
      expect(consumeDevAuthCode(expiring)).toBeNull();
    } finally {
      vi.useRealTimers();
    }
  });
});
