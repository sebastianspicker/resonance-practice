import crypto from 'crypto';
import { PrismaClient, User } from '@prisma/client';
import type { Prisma } from '@prisma/client';
import jwt from 'jsonwebtoken';
import { nanoid } from 'nanoid';
import { config, limits } from './config.js';
import { ErrorCodes } from './errorCodes.js';
import { ApiError } from './errors.js';

const devAuthCodes = new Map<string, { userId: string; expiresAt: number }>();

const JWT_ISSUER = 'resonance-api';
const JWT_AUDIENCE = 'resonance-app';
const JWT_ALGORITHM = 'HS256' as const;

export function hashToken(token: string) {
  return crypto.createHash('sha256').update(token).digest('hex');
}

export function signAccessToken(user: User) {
  const expiresIn = config.accessTokenTtlMinutes * 60;
  return jwt.sign({ sub: user.id, role: user.globalRole }, config.jwtSecret, {
    expiresIn,
    issuer: JWT_ISSUER,
    audience: JWT_AUDIENCE,
    algorithm: JWT_ALGORITHM,
  });
}

export function signRefreshToken(user: User, tokenId: string) {
  const expiresIn = config.refreshTokenTtlDays * 24 * 60 * 60;
  return jwt.sign({ sub: user.id, jti: tokenId }, config.jwtRefreshSecret, {
    expiresIn,
    issuer: JWT_ISSUER,
    audience: JWT_AUDIENCE,
    algorithm: JWT_ALGORITHM,
  });
}

export function verifyAccessToken(token: string) {
  try {
    return jwt.verify(token, config.jwtSecret, {
      algorithms: [JWT_ALGORITHM],
      issuer: JWT_ISSUER,
      audience: JWT_AUDIENCE,
    }) as jwt.JwtPayload;
  } catch {
    throw new ApiError(401, ErrorCodes.INVALID_TOKEN, 'Invalid or expired token');
  }
}

export function verifyRefreshToken(token: string) {
  try {
    return jwt.verify(token, config.jwtRefreshSecret, {
      algorithms: [JWT_ALGORITHM],
      issuer: JWT_ISSUER,
      audience: JWT_AUDIENCE,
    }) as jwt.JwtPayload;
  } catch {
    throw new ApiError(401, ErrorCodes.INVALID_REFRESH, 'Invalid or expired refresh token');
  }
}

/** Accepts PrismaClient or a Prisma transaction (which exposes the same model methods). */
type PrismaLike = Pick<PrismaClient, 'refreshToken'>;

export async function issueTokens(prisma: PrismaLike, user: User, existingFamilyId?: string) {
  const tokenId = `rt_${nanoid(24)}`;
  const familyId = existingFamilyId ?? tokenId;
  const refreshToken = signRefreshToken(user, tokenId);
  const accessToken = signAccessToken(user);

  const expiresAt = new Date(Date.now() + config.refreshTokenTtlDays * 24 * 60 * 60 * 1000);

  await prisma.refreshToken.create({
    data: {
      id: tokenId,
      userId: user.id,
      familyId,
      tokenHash: hashToken(refreshToken),
      expiresAt,
    },
  });

  return { accessToken, refreshToken };
}

async function lockAuthUser(tx: Prisma.TransactionClient, userId: string): Promise<User | null> {
  const users = await tx.$queryRaw<User[]>`
    SELECT "id", "displayName", "globalRole"
    FROM "User"
    WHERE "id" = ${userId}
    FOR UPDATE
  `;
  return users[0] ?? null;
}

export async function issueSessionTokens(prisma: PrismaClient, user: User) {
  return prisma.$transaction(async (tx) => {
    const lockedUser = await lockAuthUser(tx, user.id);
    if (!lockedUser) {
      throw new ApiError(401, ErrorCodes.USER_NOT_FOUND, 'User not found');
    }
    return issueTokens(tx, lockedUser);
  });
}

/** Serialize logout with token rotation so logout cannot miss a new token. */
export async function revokeRefreshTokenFamily(
  prisma: PrismaClient,
  userId: string
): Promise<void> {
  await prisma.$transaction(async (tx) => {
    const user = await lockAuthUser(tx, userId);
    if (!user) return;
    await tx.refreshToken.updateMany({
      where: { userId, revokedAt: null },
      data: { revokedAt: new Date() },
    });
  });
}

export async function rotateRefreshToken(prisma: PrismaClient, refreshToken: string) {
  const payload = verifyRefreshToken(refreshToken);
  const tokenId = payload.jti as string | undefined;
  const userId = payload.sub as string | undefined;

  if (!tokenId || !userId) {
    throw new ApiError(401, ErrorCodes.INVALID_REFRESH, 'Invalid refresh token payload');
  }

  const result = await prisma.$transaction(async (tx) => {
    const user = await lockAuthUser(tx, userId);
    if (!user) {
      throw new ApiError(401, ErrorCodes.USER_NOT_FOUND, 'User not found');
    }

    // Verify token hash first (before any updates)
    const record = await tx.refreshToken.findUnique({
      where: { id: tokenId },
    });

    if (!record || record.expiresAt.getTime() < Date.now()) {
      throw new ApiError(401, ErrorCodes.REFRESH_REVOKED, 'Refresh token is invalid or expired');
    }

    const providedHash = Buffer.from(hashToken(refreshToken), 'hex');
    const storedHash = Buffer.from(record.tokenHash, 'hex');

    if (
      providedHash.length !== storedHash.length ||
      !crypto.timingSafeEqual(providedHash, storedHash)
    ) {
      throw new ApiError(401, ErrorCodes.REFRESH_MISMATCH, 'Refresh token mismatch');
    }

    // Atomic conditional update: only revoke if not already revoked
    // This prevents race conditions where two concurrent requests could both succeed
    const revokedAt = new Date();
    const updateResult = await tx.refreshToken.updateMany({
      where: {
        id: tokenId,
        revokedAt: null, // Only update if not already revoked
      },
      data: { revokedAt },
    });

    // If no rows were updated, the token was already used. Revoke any active
    // descendants in this lineage before returning a sentinel; throwing inside
    // the transaction would roll the containment write back.
    if (updateResult.count === 0) {
      await tx.refreshToken.updateMany({
        where: { userId, familyId: record.familyId, revokedAt: null },
        data: { revokedAt },
      });
      return { kind: 'reused' as const };
    }

    return {
      kind: 'rotated' as const,
      tokens: await issueTokens(tx, user, record.familyId),
    };
  });

  if (result.kind === 'reused') {
    throw new ApiError(401, ErrorCodes.REFRESH_ALREADY_USED, 'Refresh token was already used');
  }
  return result.tokens;
}

export function issueDevAuthCode(userId: string) {
  // Evict expired entries before issuing a new code to prevent unbounded growth.
  const now = Date.now();
  for (const [k, v] of devAuthCodes) {
    if (v.expiresAt < now) devAuthCodes.delete(k);
  }
  const code = `dev_${nanoid(18)}`;
  devAuthCodes.set(code, { userId, expiresAt: now + limits.devAuthCodeTtlMs });
  return code;
}

export function consumeDevAuthCode(code: string) {
  const record = devAuthCodes.get(code);
  if (!record) {
    return null;
  }
  devAuthCodes.delete(code);
  if (record.expiresAt < Date.now()) {
    return null;
  }
  return record.userId;
}

export async function upsertDevUser(
  prisma: PrismaClient,
  role: 'student' | 'teacher',
  displayName?: string
) {
  const id = role === 'teacher' ? 'dev-teacher' : 'dev-student';
  const user = await prisma.user.upsert({
    where: { id },
    update: {
      displayName: displayName ?? (role === 'teacher' ? 'Dev Teacher' : 'Dev Student'),
      globalRole: role,
    },
    create: {
      id,
      displayName: displayName ?? (role === 'teacher' ? 'Dev Teacher' : 'Dev Student'),
      globalRole: role,
    },
  });

  const courseId = 'COURSE_101';
  await prisma.course.upsert({
    where: { id: courseId },
    update: { title: 'Piano Technique 101' },
    create: { id: courseId, title: 'Piano Technique 101' },
  });

  await prisma.membership.upsert({
    where: { userId_courseId: { userId: id, courseId } },
    update: { roleInCourse: role },
    create: { userId: id, courseId, roleInCourse: role },
  });

  return user;
}
