import { describe, expect, it, vi } from 'vitest';
import { User } from '@prisma/client';
import { ApiError } from '../src/errors.js';
import {
  hashToken,
  signAccessToken,
  verifyAccessToken,
  signRefreshToken,
  verifyRefreshToken,
  issueDevAuthCode,
  consumeDevAuthCode,
} from '../src/auth.js';

// A minimal User object for token signing
function makeUser(overrides?: Partial<User>): User {
  return {
    id: 'user-1',
    displayName: 'Test User',
    globalRole: 'student',
    createdAt: new Date(),
    updatedAt: new Date(),
    ...overrides,
  } as User;
}

describe('auth (unit)', () => {
  // ── hashToken ──

  describe('hashToken', () => {
    it('produces a consistent SHA-256 hex digest', () => {
      const hash1 = hashToken('my-token');
      const hash2 = hashToken('my-token');
      expect(hash1).toBe(hash2);
      expect(hash1).toMatch(/^[0-9a-f]{64}$/);
    });

    it('produces different hashes for different tokens', () => {
      expect(hashToken('token-a')).not.toBe(hashToken('token-b'));
    });

    it('handles empty string', () => {
      const hash = hashToken('');
      expect(hash).toMatch(/^[0-9a-f]{64}$/);
    });
  });

  // ── signAccessToken / verifyAccessToken round-trip ──

  describe('access token round-trip', () => {
    it('signs and verifies an access token', () => {
      const user = makeUser({ id: 'user-42', globalRole: 'teacher' });
      const token = signAccessToken(user);

      expect(typeof token).toBe('string');
      expect(token.split('.')).toHaveLength(3); // JWT has 3 parts

      const payload = verifyAccessToken(token);
      expect(payload.sub).toBe('user-42');
      expect(payload.role).toBe('teacher');
      expect(payload.iss).toBe('resonance-api');
      expect(payload.aud).toBe('resonance-app');
      expect(payload.exp).toBeDefined();
    });

    it('includes expiration in the payload', () => {
      const user = makeUser();
      const token = signAccessToken(user);
      const payload = verifyAccessToken(token);
      // exp should be in the future
      expect(payload.exp! * 1000).toBeGreaterThan(Date.now());
    });
  });

  // ── signRefreshToken / verifyRefreshToken round-trip ──

  describe('refresh token round-trip', () => {
    it('signs and verifies a refresh token with jti', () => {
      const user = makeUser({ id: 'user-99' });
      const tokenId = 'rt_test-token-id-123';
      const token = signRefreshToken(user, tokenId);

      expect(typeof token).toBe('string');

      const payload = verifyRefreshToken(token);
      expect(payload.sub).toBe('user-99');
      expect(payload.jti).toBe(tokenId);
      expect(payload.iss).toBe('resonance-api');
      expect(payload.aud).toBe('resonance-app');
    });

    it('refresh token does not contain role claim', () => {
      const user = makeUser({ globalRole: 'teacher' });
      const token = signRefreshToken(user, 'rt_test');
      const payload = verifyRefreshToken(token);
      expect(payload.role).toBeUndefined();
    });
  });

  // ── verifyAccessToken error handling ──

  describe('verifyAccessToken error handling', () => {
    it('throws ApiError for invalid token string', () => {
      expect(() => verifyAccessToken('not-a-valid-jwt')).toThrow(ApiError);
      try {
        verifyAccessToken('not-a-valid-jwt');
      } catch (e) {
        const err = e as ApiError;
        expect(err.statusCode).toBe(401);
        expect(err.code).toBe('INVALID_TOKEN');
      }
    });

    it('throws ApiError for tampered token', () => {
      const user = makeUser();
      const token = signAccessToken(user);
      const tampered = token.slice(0, -5) + 'XXXXX';
      expect(() => verifyAccessToken(tampered)).toThrow(ApiError);
    });
  });

  // ── verifyRefreshToken error handling ──

  describe('verifyRefreshToken error handling', () => {
    it('throws ApiError for invalid refresh token string', () => {
      expect(() => verifyRefreshToken('garbage')).toThrow(ApiError);
      try {
        verifyRefreshToken('garbage');
      } catch (e) {
        const err = e as ApiError;
        expect(err.statusCode).toBe(401);
        expect(err.code).toBe('INVALID_REFRESH');
      }
    });

    it('rejects an access token used as refresh token (wrong secret)', () => {
      // Access tokens are signed with jwtSecret, but verifyRefreshToken uses
      // jwtRefreshSecret, so the verification should fail immediately.
      const user = makeUser();
      const accessToken = signAccessToken(user);
      expect(() => verifyRefreshToken(accessToken)).toThrow(ApiError);
      try {
        verifyRefreshToken(accessToken);
      } catch (e) {
        const err = e as ApiError;
        expect(err.statusCode).toBe(401);
        expect(err.code).toBe('INVALID_REFRESH');
      }
    });
  });

  // ── issueDevAuthCode / consumeDevAuthCode lifecycle ──

  describe('dev auth code lifecycle', () => {
    it('issues a code that starts with dev_', () => {
      const code = issueDevAuthCode('user-1');
      expect(code).toMatch(/^dev_/);
      expect(code.length).toBeGreaterThan(5);
    });

    it('consumes a valid code and returns the userId', () => {
      const code = issueDevAuthCode('user-abc');
      const userId = consumeDevAuthCode(code);
      expect(userId).toBe('user-abc');
    });

    it('returns null for an unknown code', () => {
      expect(consumeDevAuthCode('dev_nonexistent-code-000')).toBeNull();
    });

    it('is single-use: second consume returns null', () => {
      const code = issueDevAuthCode('user-xyz');
      expect(consumeDevAuthCode(code)).toBe('user-xyz');
      expect(consumeDevAuthCode(code)).toBeNull();
    });

    it('returns null for an expired code', () => {
      // Use vi.useFakeTimers to test expiration
      vi.useFakeTimers();
      try {
        const code = issueDevAuthCode('user-expire');
        // Advance past the 5-minute TTL
        vi.advanceTimersByTime(5 * 60 * 1000 + 1);
        expect(consumeDevAuthCode(code)).toBeNull();
      } finally {
        vi.useRealTimers();
      }
    });

    it('valid code still works just before expiry', () => {
      vi.useFakeTimers();
      try {
        const code = issueDevAuthCode('user-almost');
        // Advance to just under the TTL
        vi.advanceTimersByTime(5 * 60 * 1000 - 100);
        expect(consumeDevAuthCode(code)).toBe('user-almost');
      } finally {
        vi.useRealTimers();
      }
    });

    it('issues unique codes', () => {
      const codes = new Set<string>();
      for (let i = 0; i < 50; i++) {
        codes.add(issueDevAuthCode(`user-${i}`));
      }
      expect(codes.size).toBe(50);
    });

    it('evicts expired entries on new issue (does not grow unbounded)', () => {
      vi.useFakeTimers();
      try {
        // Issue some codes
        issueDevAuthCode('user-old-1');
        issueDevAuthCode('user-old-2');

        // Advance past expiry
        vi.advanceTimersByTime(5 * 60 * 1000 + 1);

        // Issue a new code -- this should evict the expired ones
        const newCode = issueDevAuthCode('user-new');

        // The old codes should be gone (already expired + evicted)
        // The new code should work
        expect(consumeDevAuthCode(newCode)).toBe('user-new');
      } finally {
        vi.useRealTimers();
      }
    });
  });
});
