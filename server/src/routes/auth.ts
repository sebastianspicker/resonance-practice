import type { S3Client } from '@aws-sdk/client-s3';
import type { PrismaClient } from '@prisma/client';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import {
  consumeDevAuthCode,
  hashToken,
  issueDevAuthCode,
  issueTokens,
  rotateRefreshToken,
  upsertDevUser,
} from '../auth.js';
import { config, limits } from '../config.js';
import { ErrorCodes } from '../errorCodes.js';
import { ApiError } from '../errors.js';
import { requireField, requireString } from '../validation.js';

const escapeHtml = (s: string) =>
  s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

export function registerAuthRoutes(
  app: FastifyInstance,
  prisma: PrismaClient,
  _s3: S3Client,
  requireAuth: (request: FastifyRequest) => Promise<void>
) {
  const isLoopbackAddress = (ip: string | undefined) => {
    if (!ip) {
      return false;
    }
    return ip === '127.0.0.1' || ip === '::1' || ip === '::ffff:127.0.0.1';
  };

  const requireLocalDevAuth = (request: FastifyRequest) => {
    if (config.authMode !== 'dev') {
      throw new ApiError(404, ErrorCodes.NOT_FOUND, 'Not found');
    }
    if (!isLoopbackAddress(request.ip)) {
      throw new ApiError(
        403,
        ErrorCodes.DEV_AUTH_LOCAL_ONLY,
        'Dev auth routes are only available from localhost'
      );
    }
  };

  app.get('/dev/login', async (request, reply) => {
    requireLocalDevAuth(request);
    const safeName = escapeHtml(config.devUniversityName);
    const html = `<!doctype html>
<html>
  <head><title>${safeName} - Resonance Dev Login</title></head>
  <body>
    <h1>${safeName}</h1>
    <p>Resonance RC Demo Login</p>
    <p>Select a persona to continue.</p>
    <ul>
      <li><a href="/dev/authorize?role=student">Login as Student Persona</a></li>
      <li><a href="/dev/authorize?role=teacher">Login as Teacher Persona</a></li>
    </ul>
  </body>
</html>`;
    reply.type('text/html').send(html);
  });

  app.get('/dev/authorize', async (request, reply) => {
    requireLocalDevAuth(request);
    const role = (request.query as { role?: string }).role as 'student' | 'teacher' | undefined;
    if (!role || (role !== 'student' && role !== 'teacher')) {
      throw new ApiError(400, ErrorCodes.INVALID_ROLE, 'Invalid role');
    }
    const user = await upsertDevUser(prisma, role);
    const code = issueDevAuthCode(user.id);
    const redirectUrl = new URL(config.devLoginCallbackUrl);
    redirectUrl.searchParams.set('code', code);
    reply.redirect(redirectUrl.toString());
  });

  app.post('/dev/issue', async (request) => {
    requireLocalDevAuth(request);
    const body = request.body as { role?: 'student' | 'teacher'; userId?: string };
    const role = body?.role ?? 'student';
    let user;
    if (body?.userId) {
      user = await prisma.user.findUnique({ where: { id: body.userId } });
      if (!user) {
        throw new ApiError(404, ErrorCodes.USER_NOT_FOUND, 'User not found');
      }
    } else {
      user = await upsertDevUser(prisma, role);
    }
    const code = issueDevAuthCode(user.id);
    return { code };
  });

  app.post(
    '/auth/session',
    {
      config: {
        rateLimit: { max: limits.authRateLimitMax, timeWindow: limits.authRateLimitWindow },
      },
    },
    async (request, reply) => {
      const body = request.body as { code?: string; redirectUri?: string };
      const code = requireString(requireField(body?.code, 'code'), 'code', {
        max: limits.maxAuthCodeLength,
      });
      const _redirectUri = body?.redirectUri;

      if (config.authMode !== 'dev') {
        // Production auth: validate redirectUri against allowlist
        // The redirectUri must match one of the registered callback URLs for the client
        // Example: if (!config.allowedRedirectUris.includes(redirectUri)) { throw ... }
        // For now, production auth is not implemented
        throw new ApiError(501, ErrorCodes.AUTH_NOT_CONFIGURED, 'Production auth not configured');
      }

      // Dev mode: redirectUri validation is intentionally skipped for development convenience
      // The redirectUri is not used in dev mode - tokens are returned directly
      // SECURITY NOTE: When implementing production auth, redirectUri MUST be validated

      const userId = consumeDevAuthCode(code);
      if (!userId) {
        throw new ApiError(401, ErrorCodes.INVALID_CODE, 'Invalid or expired auth code');
      }
      const user = await prisma.user.findUnique({ where: { id: userId } });
      if (!user) {
        throw new ApiError(401, ErrorCodes.USER_NOT_FOUND, 'User not found');
      }
      const tokens = await issueTokens(prisma, user);
      return reply.status(201).send({
        ...tokens,
        user: { id: user.id, displayName: user.displayName, globalRole: user.globalRole },
      });
    }
  );

  app.post(
    '/auth/refresh',
    {
      config: {
        rateLimit: { max: limits.authRateLimitMax, timeWindow: limits.authRateLimitWindow },
      },
    },
    async (request) => {
      if (config.authMode !== 'dev') {
        throw new ApiError(501, ErrorCodes.AUTH_NOT_CONFIGURED, 'Production auth not configured');
      }
      const body = request.body as { refreshToken?: string };
      const refreshToken = requireString(
        requireField(body?.refreshToken, 'refreshToken'),
        'refreshToken',
        { max: limits.maxAuthCodeLength }
      );
      const tokens = await rotateRefreshToken(prisma, refreshToken);

      // Clean up revoked tokens older than 30 days (best-effort)
      const thirtyDaysAgo = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000);
      try {
        await prisma.refreshToken.deleteMany({
          where: { revokedAt: { not: null, lt: thirtyDaysAgo } },
        });
      } catch (e) {
        request.log.warn({ err: e }, 'refresh_token_cleanup_failed');
      }

      return tokens;
    }
  );

  app.get('/auth/me', { preHandler: requireAuth }, async (request) => {
    const user = request.user!;
    const userRecord = await prisma.user.findUnique({ where: { id: user.id } });
    if (!userRecord) {
      throw new ApiError(404, ErrorCodes.USER_NOT_FOUND, 'User not found');
    }
    return {
      id: userRecord.id,
      displayName: userRecord.displayName,
      globalRole: userRecord.globalRole,
    };
  });

  app.post('/auth/logout', async (request) => {
    const body = request.body as { refreshToken?: string } | undefined;

    // If a refresh token is provided, revoke the token family without requiring auth.
    // This allows clients to revoke tokens even when the access token has expired.
    if (body?.refreshToken) {
      const tokenHash = hashToken(body.refreshToken);
      const token = await prisma.refreshToken.findFirst({
        where: { tokenHash },
      });
      if (token) {
        await prisma.refreshToken.updateMany({
          where: { userId: token.userId, revokedAt: null },
          data: { revokedAt: new Date() },
        });
      }
      return { success: true };
    }

    // Fall back to access-token-based logout
    await requireAuth(request);
    const user = request.user!;

    // Revoke all refresh tokens for this user
    await prisma.refreshToken.updateMany({
      where: {
        userId: user.id,
        revokedAt: null,
      },
      data: {
        revokedAt: new Date(),
      },
    });

    return { success: true };
  });
}
