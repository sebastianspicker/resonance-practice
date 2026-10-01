import type { PrismaClient } from '@prisma/client';

const REVOKED_REFRESH_TOKEN_RETENTION_MS = 30 * 24 * 60 * 60_000;
const DEFAULT_CLEANUP_LIMIT = 500;

/** Remove one bounded batch of old revoked tokens outside authentication requests. */
export async function cleanupRevokedRefreshTokens(prisma: PrismaClient): Promise<number> {
  const revokedBefore = new Date(Date.now() - REVOKED_REFRESH_TOKEN_RETENTION_MS);
  const tokens = await prisma.refreshToken.findMany({
    where: { revokedAt: { not: null, lt: revokedBefore } },
    select: { id: true },
    orderBy: [{ revokedAt: 'asc' }, { id: 'asc' }],
    take: DEFAULT_CLEANUP_LIMIT,
  });
  if (tokens.length === 0) return 0;
  const result = await prisma.refreshToken.deleteMany({
    where: { id: { in: tokens.map((token) => token.id) } },
  });
  return result.count;
}
