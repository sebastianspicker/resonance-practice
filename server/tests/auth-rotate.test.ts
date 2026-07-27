// Covers refresh-token rotation, replay containment, and transactional revocation behavior.
import { describe, expect, it, vi } from 'vitest';
import jwt from 'jsonwebtoken';
import { ApiError } from '../src/errors.js';
import { rotateRefreshToken, signRefreshToken, hashToken } from '../src/auth.js';
import { config } from '../src/config.js';
import { makeUser } from './support/authTestUtils.js';

// Exercise malformed claims, expiry, hash mismatch, replay, and deleted users.

function signManualRefreshToken(payload: object) {
  return jwt.sign(payload, config.jwtRefreshSecret, {
    expiresIn: 3600,
    issuer: 'resonance-api',
    audience: 'resonance-app',
    algorithm: 'HS256',
  });
}

function transactionalPrisma(mockTx: object) {
  return {
    $transaction: vi.fn(async (operation: (tx: object) => unknown) => operation(mockTx)),
  } as any;
}

function refreshTokenTransaction(
  user: ReturnType<typeof makeUser>,
  record: unknown,
  refreshTokenOverrides: Record<string, unknown> = {}
): any {
  return {
    $queryRaw: vi.fn().mockResolvedValue([user]),
    refreshToken: {
      findUnique: vi.fn().mockResolvedValue(record),
      ...refreshTokenOverrides,
    },
  };
}

function refreshTokenRecord(
  user: ReturnType<typeof makeUser>,
  tokenId: string,
  token: string,
  overrides: Record<string, unknown> = {}
) {
  return {
    id: tokenId,
    userId: user.id,
    tokenHash: hashToken(token),
    expiresAt: new Date(Date.now() + 86_400_000),
    revokedAt: null,
    ...overrides,
  };
}

async function expectRefreshError(operation: Promise<unknown>, code: string, message?: string) {
  try {
    await operation;
    expect.unreachable('should have thrown');
  } catch (error) {
    const refreshError = error as ApiError;
    expect(refreshError).toBeInstanceOf(ApiError);
    expect(refreshError.statusCode).toBe(401);
    expect(refreshError.code).toBe(code);
    if (message) expect(refreshError.message).toBe(message);
  }
}

describe('refresh-token rotation errors', () => {
  // ── Missing tokenId in JWT payload ──
  it('throws INVALID_REFRESH when JWT payload has no jti (tokenId)', async () => {
    // Sign a JWT manually without jti using the refresh secret
    const token = signManualRefreshToken({ sub: 'user-1' });

    await expectRefreshError(
      rotateRefreshToken({} as any, token),
      'INVALID_REFRESH',
      'Invalid refresh token payload'
    );
  });

  // ── Missing userId in JWT payload ──
  it('throws INVALID_REFRESH when JWT payload has no sub (userId)', async () => {
    const token = signManualRefreshToken({ jti: 'rt_test123' });

    await expectRefreshError(
      rotateRefreshToken({} as any, token),
      'INVALID_REFRESH',
      'Invalid refresh token payload'
    );
  });

  // ── Expired refresh token record (expiresAt in the past) ──
  it('throws REFRESH_REVOKED when token record has expired expiresAt', async () => {
    const user = makeUser();
    const tokenId = 'rt_expired-record';
    const token = signRefreshToken(user, tokenId);

    const mockTx = {
      ...refreshTokenTransaction(
        user,
        refreshTokenRecord(user, tokenId, token, { expiresAt: new Date(Date.now() - 1_000) }),
        { updateMany: vi.fn() }
      ),
      user: {
        findUnique: vi.fn(),
      },
    };

    await expectRefreshError(
      rotateRefreshToken(transactionalPrisma(mockTx), token),
      'REFRESH_REVOKED',
      'Refresh token is invalid or expired'
    );
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

    await expectRefreshError(
      rotateRefreshToken(transactionalPrisma(mockTx), token),
      'REFRESH_REVOKED'
    );
  });

  // ── Hash mismatch (timing-safe comparison fails) ──
  it('throws REFRESH_MISMATCH when token hash does not match stored hash', async () => {
    const user = makeUser();
    const tokenId = 'rt_hash-mismatch';
    const token = signRefreshToken(user, tokenId);

    const mockTx = refreshTokenTransaction(
      user,
      refreshTokenRecord(user, tokenId, token, {
        tokenHash: hashToken('completely-different-token'),
      })
    );

    await expectRefreshError(
      rotateRefreshToken(transactionalPrisma(mockTx), token),
      'REFRESH_MISMATCH',
      'Refresh token mismatch'
    );
  });

  // ── User deleted between token lookup and reissue ──
  it('throws USER_NOT_FOUND when user is deleted between token lookup and reissue', async () => {
    const user = makeUser({ id: 'user-deleted' });
    const tokenId = 'rt_user-deleted';
    const token = signRefreshToken(user, tokenId);

    const mockTx = {
      $queryRaw: vi.fn().mockResolvedValue([]),
      refreshToken: {
        findUnique: vi.fn().mockResolvedValue(refreshTokenRecord(user, tokenId, token)),
        updateMany: vi.fn().mockResolvedValue({ count: 1 }), // token revoked successfully
        create: vi.fn(),
      },
      user: {
        findUnique: vi.fn().mockResolvedValue(null), // user not found
      },
    };

    await expectRefreshError(
      rotateRefreshToken(transactionalPrisma(mockTx), token),
      'USER_NOT_FOUND',
      'User not found'
    );
  });

  // ── Race condition: token already used (updateMany returns 0) ──
  it('commits lineage revocation before reporting a reused refresh token', async () => {
    const user = makeUser();
    const tokenId = 'rt_already-used';
    const familyId = 'rt_family-1';
    const token = signRefreshToken(user, tokenId);

    const mockTx = refreshTokenTransaction(
      user,
      refreshTokenRecord(user, tokenId, token, { familyId }),
      { updateMany: vi.fn().mockResolvedValue({ count: 0 }) }
    );

    let transactionCommitted = false;
    const mockPrisma = {
      $transaction: vi.fn(async (fn: (tx: any) => any) => {
        const result = await fn(mockTx);
        transactionCommitted = true;
        return result;
      }),
    } as any;

    await expectRefreshError(rotateRefreshToken(mockPrisma, token), 'REFRESH_ALREADY_USED');
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

    const mockTx = refreshTokenTransaction(
      user,
      refreshTokenRecord(user, tokenId, token, { familyId }),
      { updateMany: vi.fn().mockResolvedValue({ count: 1 }), create }
    );

    const result = await rotateRefreshToken(transactionalPrisma(mockTx), token);

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
