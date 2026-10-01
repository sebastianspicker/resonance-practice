import { describe, expect, it } from 'vitest';
import { cleanupRevokedRefreshTokens } from '../src/modules/identity/application/maintenance.js';

describe('identity maintenance', () => {
  it('selects and deletes only one bounded batch of old revoked tokens', async () => {
    const calls: unknown[] = [];
    const prisma = {
      refreshToken: {
        findMany: async (args: unknown) => {
          calls.push(args);
          return [{ id: 'old-1' }, { id: 'old-2' }];
        },
        deleteMany: async (args: unknown) => {
          calls.push(args);
          return { count: 2 };
        },
      },
    };
    const expectedBefore = Date.now() - 30 * 24 * 60 * 60_000;

    await expect(cleanupRevokedRefreshTokens(prisma as never)).resolves.toBe(2);
    const selection = calls[0] as {
      where: { revokedAt: { lt: Date } };
      take: number;
    };
    expect(selection.where.revokedAt.lt.getTime()).toBeGreaterThanOrEqual(expectedBefore);
    expect(selection.take).toBe(500);
    expect(calls[1]).toEqual({ where: { id: { in: ['old-1', 'old-2'] } } });
  });
});
