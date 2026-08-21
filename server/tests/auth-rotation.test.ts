import { describe, expect, it } from 'vitest';
import { issueSessionTokens, revokeRefreshTokenFamily, rotateRefreshToken } from '../src/auth.js';
import { installBasicSuite, prisma } from './support/testUtils.js';

describe('refresh-token family containment', () => {
  installBasicSuite();

  it('rotates once, contains replay, and serializes rotation with logout', async () => {
    const user = (await prisma.user.findUnique({ where: { id: 'student-1' } }))!;
    const initial = await issueSessionTokens(prisma, user);
    const rotated = await rotateRefreshToken(prisma, initial.refreshToken);

    await expect(rotateRefreshToken(prisma, initial.refreshToken)).rejects.toMatchObject({
      status: 401,
    });
    await expect(rotateRefreshToken(prisma, rotated.refreshToken)).rejects.toMatchObject({
      status: 401,
    });
    expect(await prisma.refreshToken.count({ where: { userId: user.id, revokedAt: null } })).toBe(
      0
    );

    const concurrent = await issueSessionTokens(prisma, user);
    const [rotation] = await Promise.allSettled([
      rotateRefreshToken(prisma, concurrent.refreshToken),
      revokeRefreshTokenFamily(prisma, user.id),
    ]);
    expect(await prisma.refreshToken.count({ where: { userId: user.id, revokedAt: null } })).toBe(
      0
    );
    if (rotation.status === 'fulfilled') {
      await expect(rotateRefreshToken(prisma, rotation.value.refreshToken)).rejects.toMatchObject({
        status: 401,
      });
    }
  });
});
