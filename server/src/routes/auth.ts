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
import { config, oidcConfig, limits } from '../config.js';
import { ErrorCodes } from '../errorCodes.js';
import { ApiError } from '../errors.js';
import { requireEnum, requireField, requireString } from '../validation.js';
import {
  consumeOidcState,
  consumeProdAuthCode,
  displayNameFromClaims,
  getOidcClient,
  issueProdAuthCode,
  issueOidcState,
  roleFromClaims,
  ssoUserId,
} from '../oidc.js';

const escapeHtml = (s: string) =>
  s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');

const buildDevLoginHtml = (universityName: string) => {
  const safeName = escapeHtml(universityName);
  return [
    '<!doctype html>',
    '<html>',
    '  <head><title>',
    safeName,
    ' - Resonance Dev Login</title></head>',
    '  <body>',
    '    <h1>',
    safeName,
    '</h1>',
    '    <p>Resonance RC Demo Login</p>',
    '    <p>Select a persona to continue.</p>',
    '    <ul>',
    '      <li><a href="/dev/authorize?role=student">Login as Student Persona</a></li>',
    '      <li><a href="/dev/authorize?role=teacher">Login as Teacher Persona</a></li>',
    '    </ul>',
    '  </body>',
    '</html>',
  ].join('\n');
};

export function registerAuthRoutes(
  app: FastifyInstance,
  prisma: PrismaClient,
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

  app.get('/auth/login', async (request, reply) => {
    // Keep the iOS app on one stable login URL. The server owns whether that
    // means localhost-only dev auth or the production OIDC redirect.
    if (config.authMode === 'dev') {
      requireLocalDevAuth(request);
      return reply.redirect('/dev/login');
    }
    return reply.redirect('/auth/oidc/login');
  });

  app.get('/dev/login', async (request, reply) => {
    requireLocalDevAuth(request);
    reply.type('text/html').send(buildDevLoginHtml(config.devUniversityName));
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
    if (
      request.body !== undefined &&
      (typeof request.body !== 'object' || request.body === null || Array.isArray(request.body))
    ) {
      throw new ApiError(400, ErrorCodes.VALIDATION_ERROR, 'Invalid request body');
    }
    const body = (request.body ?? {}) as Record<string, unknown>;
    const role =
      body.role === undefined
        ? 'student'
        : requireEnum(body.role, 'role', ['student', 'teacher'] as const);
    const userId = body.userId === undefined ? undefined : requireString(body.userId, 'userId');
    let user;
    if (userId) {
      user = await prisma.user.findUnique({ where: { id: userId } });
      if (!user) {
        throw new ApiError(404, ErrorCodes.USER_NOT_FOUND, 'User not found');
      }
    } else {
      user = await upsertDevUser(prisma, role);
    }
    const code = issueDevAuthCode(user.id);
    return { code };
  });

  // ── OIDC routes (production only) ───────────────────────────────────────────

  app.get('/auth/oidc/login', async (request, reply) => {
    if (!oidcConfig) {
      throw new ApiError(
        501,
        ErrorCodes.AUTH_NOT_CONFIGURED,
        'OIDC is not configured on this server'
      );
    }
    const client = await getOidcClient();
    const state = issueOidcState();
    const authorizationUrl = client.authorizationUrl({
      scope: oidcConfig.scopes,
      state,
    });
    reply.redirect(authorizationUrl);
  });

  app.get('/auth/oidc/callback', async (request, reply) => {
    if (!oidcConfig) {
      throw new ApiError(
        501,
        ErrorCodes.AUTH_NOT_CONFIGURED,
        'OIDC is not configured on this server'
      );
    }
    const client = await getOidcClient();
    const params = client.callbackParams(request.raw);
    const state = typeof params.state === 'string' ? params.state : undefined;

    if (!state || !consumeOidcState(state)) {
      throw new ApiError(
        400,
        ErrorCodes.VALIDATION_ERROR,
        'Invalid or expired OIDC state parameter'
      );
    }

    let tokenSet;
    try {
      tokenSet = await client.oauthCallback(oidcConfig.redirectUri, params, { state });
    } catch (err) {
      request.log.warn({ err }, 'oidc_callback_failed');
      throw new ApiError(401, ErrorCodes.INVALID_CODE, 'OIDC token exchange failed');
    }

    const claims = tokenSet.claims();
    const sub = claims.sub;
    if (!sub) {
      throw new ApiError(401, ErrorCodes.INVALID_TOKEN, 'OIDC token missing sub claim');
    }

    const userId = ssoUserId(sub);
    const displayName = displayNameFromClaims(claims as Record<string, unknown>);
    const globalRole = roleFromClaims(claims as Record<string, unknown>);

    await prisma.user.upsert({
      where: { id: userId },
      update: { displayName, globalRole },
      create: { id: userId, displayName, globalRole },
    });

    const code = issueProdAuthCode(userId);

    // Redirect to the app's custom URL scheme with the internal code.
    // The iOS app registers resonance:// so ASWebAuthenticationSession captures this redirect.
    const appCallbackUrl = new URL('resonance://auth-callback');
    appCallbackUrl.searchParams.set('code', code);
    reply.redirect(appCallbackUrl.toString());
  });

  // ── Session exchange ─────────────────────────────────────────────────────────

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

      // This exchange consumes an internal one-time code, not the raw OIDC code.
      // In production, still pin redirectUri to the registered OIDC callback or
      // app scheme so clients cannot replay codes through an unexpected target.
      const redirectUri = body?.redirectUri;
      if (config.authMode === 'prod' && oidcConfig && redirectUri) {
        if (redirectUri !== oidcConfig.redirectUri && redirectUri !== 'resonance://auth-callback') {
          throw new ApiError(400, ErrorCodes.VALIDATION_ERROR, 'Invalid redirectUri');
        }
      }

      let userId: string | null = null;

      if (config.authMode === 'dev') {
        userId = consumeDevAuthCode(code);
      } else {
        userId = consumeProdAuthCode(code);
      }

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
    if (
      request.body !== undefined &&
      request.body !== null &&
      (typeof request.body !== 'object' || Array.isArray(request.body))
    ) {
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
      const tokenHash = hashToken(refreshToken);
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
