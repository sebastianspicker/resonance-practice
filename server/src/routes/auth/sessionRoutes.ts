import type { PrismaClient } from '@prisma/client';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import {
  consumeDevAuthCode,
  hashToken,
  issueSessionTokens,
  revokeRefreshTokenFamily,
  rotateRefreshToken,
} from '../../auth.js';
import { config, limits, oidcConfig } from '../../config.js';
import { ErrorCodes } from '../../errorCodes.js';
import { ApiError } from '../../errors.js';
import { consumeProdAuthCode } from '../../oidc.js';
import { requireField, requireString } from '../../validation.js';

type RequireAuth = (request: FastifyRequest) => Promise<void>;

export function registerSessionRoutes(
  app: FastifyInstance,
  prisma: PrismaClient,
  requireAuth: RequireAuth
) {
  registerSessionExchangeRoute(app, prisma);
  registerRefreshRoute(app, prisma);
  registerCurrentUserRoute(app, prisma, requireAuth);
  registerLogoutRoute(app, prisma, requireAuth);
}

function registerSessionExchangeRoute(app: FastifyInstance, prisma: PrismaClient) {
  app.post('/auth/session', { config: { rateLimit: authRateLimit } }, async (request, reply) => {
    const body = request.body as { code?: string; redirectUri?: string };
    const code = requireString(requireField(body?.code, 'code'), 'code', {
      max: limits.maxAuthCodeLength,
    });

    validateRedirectUri(body?.redirectUri);
    const userId = await consumeAuthCode(prisma, code);
    if (!userId) {
      throw new ApiError(401, ErrorCodes.INVALID_CODE, 'Invalid or expired auth code');
    }

    const user = await prisma.user.findUnique({ where: { id: userId } });
    if (!user) {
      throw new ApiError(401, ErrorCodes.USER_NOT_FOUND, 'User not found');
    }
    const tokens = await issueSessionTokens(prisma, user);
    return reply.status(201).send({
      ...tokens,
      user: { id: user.id, displayName: user.displayName, globalRole: user.globalRole },
    });
  });
}

function registerRefreshRoute(app: FastifyInstance, prisma: PrismaClient) {
  app.post('/auth/refresh', { config: { rateLimit: authRateLimit } }, async (request) => {
    const body = request.body as { refreshToken?: string };
    const refreshToken = requireString(
      requireField(body?.refreshToken, 'refreshToken'),
      'refreshToken',
      { max: limits.maxAuthCodeLength }
    );
    const tokens = await rotateRefreshToken(prisma, refreshToken);
    await removeExpiredRefreshTokens(prisma, request);
    return tokens;
  });
}

function registerCurrentUserRoute(
  app: FastifyInstance,
  prisma: PrismaClient,
  requireAuth: RequireAuth
) {
  app.get('/auth/me', { preHandler: requireAuth }, async (request) => {
    const userRecord = await prisma.user.findUnique({ where: { id: request.user!.id } });
    if (!userRecord) {
      throw new ApiError(404, ErrorCodes.USER_NOT_FOUND, 'User not found');
    }
    return {
      id: userRecord.id,
      displayName: userRecord.displayName,
      globalRole: userRecord.globalRole,
    };
  });
}

function registerLogoutRoute(app: FastifyInstance, prisma: PrismaClient, requireAuth: RequireAuth) {
  app.post('/auth/logout', async (request) => {
    if (!isOptionalObject(request.body)) {
      throw new ApiError(400, ErrorCodes.VALIDATION_ERROR, 'Invalid request body');
    }
    const body = request.body as Record<string, unknown> | undefined;

    // If a refresh token is provided, revoke the token family without requiring auth.
    // This allows clients to revoke tokens even when the access token has expired.
    if (body && 'refreshToken' in body) {
      const refreshToken = requireString(
        requireField(body.refreshToken, 'refreshToken'),
        'refreshToken',
        { max: limits.maxAuthCodeLength }
      );
      const token = await prisma.refreshToken.findFirst({
        where: { tokenHash: hashToken(refreshToken) },
      });
      if (token) {
        await revokeRefreshTokenFamily(prisma, token.userId);
      }
      return { success: true };
    }

    // Fall back to access-token-based logout.
    await requireAuth(request);
    await revokeRefreshTokenFamily(prisma, request.user!.id);
    return { success: true };
  });
}

const authRateLimit = {
  max: limits.authRateLimitMax,
  timeWindow: limits.authRateLimitWindow,
};

function validateRedirectUri(redirectUri: string | undefined): void {
  if (
    config.authMode === 'prod' &&
    oidcConfig &&
    redirectUri &&
    redirectUri !== oidcConfig.redirectUri &&
    redirectUri !== 'resonance://auth-callback'
  ) {
    throw new ApiError(400, ErrorCodes.VALIDATION_ERROR, 'Invalid redirectUri');
  }
}

function consumeAuthCode(
  prisma: PrismaClient,
  code: string
): Promise<string | null> | string | null {
  return config.authMode === 'dev' ? consumeDevAuthCode(code) : consumeProdAuthCode(prisma, code);
}

async function removeExpiredRefreshTokens(
  prisma: PrismaClient,
  request: FastifyRequest
): Promise<void> {
  // Clean up revoked tokens older than 30 days (best-effort).
  const thirtyDaysAgo = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000);
  try {
    await prisma.refreshToken.deleteMany({
      where: { revokedAt: { not: null, lt: thirtyDaysAgo } },
    });
  } catch (err) {
    request.log.warn({ err }, 'refresh_token_cleanup_failed');
  }
}

function isOptionalObject(value: unknown): boolean {
  return value == null || (typeof value === 'object' && !Array.isArray(value));
}
