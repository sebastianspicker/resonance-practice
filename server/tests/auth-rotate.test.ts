import { describe, expect, it, vi } from 'vitest';
import jwt from 'jsonwebtoken';
import { User } from '@prisma/client';
import { ApiError } from '../src/errors.js';
import { rotateRefreshToken, signRefreshToken, hashToken } from '../src/auth.js';
import { config } from '../src/config.js';

/**
 * Unit tests for rotateRefreshToken covering specific uncovered branches:
 * - Missing tokenId or userId in JWT payload
 * - Expired refresh token record (expiresAt in the past)
 * - Hash mismatch (timing-safe comparison fails)
 * - User deleted between token lookup and reissue
 */

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

describe('rotateRefreshToken branch coverage', () => {
  // ── Missing tokenId in JWT payload ──
  it('throws INVALID_REFRESH when JWT payload has no jti (tokenId)', async () => {
    // Sign a JWT manually without jti using the refresh secret
    const token = jwt.sign({ sub: 'user-1' }, config.jwtRefreshSecret, {
      expiresIn: 3600,
      issuer: 'resonance-api',
      audience: 'resonance-app',
      algorithm: 'HS256',
    });

    const mockPrisma = {} as any;

    try {
      await rotateRefreshToken(mockPrisma, token);
      expect.unreachable('should have thrown');
    } catch (e) {
      const err = e as ApiError;
      expect(err).toBeInstanceOf(ApiError);
      expect(err.statusCode).toBe(401);
      expect(err.code).toBe('INVALID_REFRESH');
      expect(err.message).toBe('Invalid refresh token payload');
    }
  });

  // ── Missing userId in JWT payload ──
  it('throws INVALID_REFRESH when JWT payload has no sub (userId)', async () => {
    const token = jwt.sign({ jti: 'rt_test123' }, config.jwtRefreshSecret, {
      expiresIn: 3600,
      issuer: 'resonance-api',
      audience: 'resonance-app',
      algorithm: 'HS256',
    });

    const mockPrisma = {} as any;

    try {
      await rotateRefreshToken(mockPrisma, token);
      expect.unreachable('should have thrown');
    } catch (e) {
      const err = e as ApiError;
      expect(err).toBeInstanceOf(ApiError);
      expect(err.statusCode).toBe(401);
      expect(err.code).toBe('INVALID_REFRESH');
      expect(err.message).toBe('Invalid refresh token payload');
    }
  });

  // ── Expired refresh token record (expiresAt in the past) ──
  it('throws REFRESH_REVOKED when token record has expired expiresAt', async () => {
    const user = makeUser();
    const tokenId = 'rt_expired-record';
    const token = signRefreshToken(user, tokenId);

    const mockTx = {
      $queryRaw: vi.fn().mockResolvedValue([user]),
      refreshToken: {
        findUnique: vi.fn().mockResolvedValue({
          id: tokenId,
          userId: user.id,
          tokenHash: hashToken(token),
          expiresAt: new Date(Date.now() - 1000), // expired 1 second ago
          revokedAt: null,
        }),
        updateMany: vi.fn(),
      },
      user: {
        findUnique: vi.fn(),
      },
    };

    const mockPrisma = {
      $transaction: vi.fn(async (fn: (tx: any) => any) => fn(mockTx)),
    } as any;

    try {
      await rotateRefreshToken(mockPrisma, token);
      expect.unreachable('should have thrown');
    } catch (e) {
      const err = e as ApiError;
      expect(err).toBeInstanceOf(ApiError);
      expect(err.statusCode).toBe(401);
      expect(err.code).toBe('REFRESH_REVOKED');
      expect(err.message).toBe('Refresh token is invalid or expired');
    }
  });

  // ── Token record not found (null) ──
  it('throws REFRESH_REVOKED when token record is not found', async () => {
    const user = makeUser();
    const tokenId = 'rt_not-found';
    const token = signRefreshToken(user, tokenId);

    const mockTx = {
      $queryRaw: vi.fn().mockResolvedValue([user]),
      refreshToken: {
        findUnique: vi.fn().mockResolvedValue(null),
      },
    };

    const mockPrisma = {
      $transaction: vi.fn(async (fn: (tx: any) => any) => fn(mockTx)),
    } as any;

    try {
      await rotateRefreshToken(mockPrisma, token);
      expect.unreachable('should have thrown');
    } catch (e) {
      const err = e as ApiError;
      expect(err).toBeInstanceOf(ApiError);
      expect(err.statusCode).toBe(401);
      expect(err.code).toBe('REFRESH_REVOKED');
    }
  });

  // ── Hash mismatch (timing-safe comparison fails) ──
  it('throws REFRESH_MISMATCH when token hash does not match stored hash', async () => {
    const user = makeUser();
    const tokenId = 'rt_hash-mismatch';
    const token = signRefreshToken(user, tokenId);

    const mockTx = {
      $queryRaw: vi.fn().mockResolvedValue([user]),
      refreshToken: {
        findUnique: vi.fn().mockResolvedValue({
          id: tokenId,
          userId: user.id,
          tokenHash: hashToken('completely-different-token'), // wrong hash
          expiresAt: new Date(Date.now() + 86400000), // valid, not expired
          revokedAt: null,
        }),
      },
    };

    const mockPrisma = {
      $transaction: vi.fn(async (fn: (tx: any) => any) => fn(mockTx)),
    } as any;

    try {
      await rotateRefreshToken(mockPrisma, token);
      expect.unreachable('should have thrown');
    } catch (e) {
      const err = e as ApiError;
      expect(err).toBeInstanceOf(ApiError);
      expect(err.statusCode).toBe(401);
      expect(err.code).toBe('REFRESH_MISMATCH');
      expect(err.message).toBe('Refresh token mismatch');
    }
  });

  // ── User deleted between token lookup and reissue ──
  it('throws USER_NOT_FOUND when user is deleted between token lookup and reissue', async () => {
    const user = makeUser({ id: 'user-deleted' });
    const tokenId = 'rt_user-deleted';
    const token = signRefreshToken(user, tokenId);

    const mockTx = {
      $queryRaw: vi.fn().mockResolvedValue([]),
      refreshToken: {
        findUnique: vi.fn().mockResolvedValue({
          id: tokenId,
          userId: user.id,
          tokenHash: hashToken(token),
          expiresAt: new Date(Date.now() + 86400000),
          revokedAt: null,
        }),
        updateMany: vi.fn().mockResolvedValue({ count: 1 }), // token revoked successfully
        create: vi.fn(),
      },
      user: {
        findUnique: vi.fn().mockResolvedValue(null), // user not found
      },
    };

    const mockPrisma = {
      $transaction: vi.fn(async (fn: (tx: any) => any) => fn(mockTx)),
    } as any;

    try {
      await rotateRefreshToken(mockPrisma, token);
      expect.unreachable('should have thrown');
    } catch (e) {
      const err = e as ApiError;
      expect(err).toBeInstanceOf(ApiError);
      expect(err.statusCode).toBe(401);
      expect(err.code).toBe('USER_NOT_FOUND');
      expect(err.message).toBe('User not found');
    }
  });

  // ── Race condition: token already used (updateMany returns 0) ──
  it('commits lineage revocation before reporting a reused refresh token', async () => {
    const user = makeUser();
    const tokenId = 'rt_already-used';
    const familyId = 'rt_family-1';
    const token = signRefreshToken(user, tokenId);

    const mockTx = {
      $queryRaw: vi.fn().mockResolvedValue([user]),
      refreshToken: {
        findUnique: vi.fn().mockResolvedValue({
          id: tokenId,
          userId: user.id,
          familyId,
          tokenHash: hashToken(token),
          expiresAt: new Date(Date.now() + 86400000),
          revokedAt: null,
        }),
        updateMany: vi.fn().mockResolvedValue({ count: 0 }), // already revoked
      },
    };

    let transactionCommitted = false;
    const mockPrisma = {
      $transaction: vi.fn(async (fn: (tx: any) => any) => {
        const result = await fn(mockTx);
        transactionCommitted = true;
        return result;
      }),
    } as any;

    try {
      await rotateRefreshToken(mockPrisma, token);
      expect.unreachable('should have thrown');
    } catch (e) {
      const err = e as ApiError;
      expect(err).toBeInstanceOf(ApiError);
      expect(err.statusCode).toBe(401);
      expect(err.code).toBe('REFRESH_ALREADY_USED');
    }
    expect(transactionCommitted).toBe(true);
    expect(mockTx.refreshToken.updateMany).toHaveBeenNthCalledWith(2, {
      where: { userId: user.id, familyId, revokedAt: null },
      data: { revokedAt: expect.any(Date) },
    });
  });

  it('keeps a rotated refresh token in the same replay-containment family', async () => {
    const user = makeUser();
    const tokenId = 'rt_current';
    const familyId = 'rt_original-family';
    const token = signRefreshToken(user, tokenId);
    const create = vi.fn().mockResolvedValue({});

    const mockTx = {
      $queryRaw: vi.fn().mockResolvedValue([user]),
      refreshToken: {
        findUnique: vi.fn().mockResolvedValue({
          id: tokenId,
          userId: user.id,
          familyId,
          tokenHash: hashToken(token),
          expiresAt: new Date(Date.now() + 86400000),
          revokedAt: null,
        }),
        updateMany: vi.fn().mockResolvedValue({ count: 1 }),
        create,
      },
    };

    const mockPrisma = {
      $transaction: vi.fn(async (fn: (tx: any) => any) => fn(mockTx)),
    } as any;

    const result = await rotateRefreshToken(mockPrisma, token);

    expect(result.accessToken).toEqual(expect.any(String));
    expect(result.refreshToken).toEqual(expect.any(String));
    expect(create).toHaveBeenCalledWith({
      data: expect.objectContaining({
        userId: user.id,
        familyId,
      }),
    });
  });
});
