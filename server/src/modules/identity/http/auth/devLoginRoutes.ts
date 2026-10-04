import type { PrismaClient } from '@prisma/client';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import {
  issueDevAuthCode,
  upsertDevUser,
  validateAppCodeChallenge,
} from '../../application/auth.js';
import { config } from '../../../../platform/config.js';
import { ErrorCodes } from '../../../../platform/http/errorCodes.js';
import { ApiError } from '../../../../platform/http/errors.js';
import { requireEnum, requireString } from '../../../../platform/http/input.js';
import { apiRateLimit } from '../../../../platform/http/rateLimit.js';

export function registerDevLoginRoutes(app: FastifyInstance, prisma: PrismaClient) {
  registerApplicationLoginRoute(app);
  registerDevLoginRoute(app);
  registerDevAuthorizeRoute(app, prisma);
  registerDevIssueRoute(app, prisma);
}

function registerApplicationLoginRoute(app: FastifyInstance) {
  app.get('/auth/login', { config: { rateLimit: apiRateLimit } }, async (request, reply) => {
    // Keep the iOS app on one stable login URL. The server owns whether that
    // means localhost-only dev auth or the production OIDC redirect.
    const appCodeChallenge = validateAppCodeChallenge(
      (request.query as { app_code_challenge?: unknown }).app_code_challenge
    );
    if (config.authMode === 'dev') {
      requireLocalDevAuth(request);
      return reply.redirect(
        `/dev/login?app_code_challenge=${encodeURIComponent(appCodeChallenge)}`
      );
    }
    return reply.redirect(
      `/auth/oidc/login?app_code_challenge=${encodeURIComponent(appCodeChallenge)}`
    );
  });
}

function registerDevLoginRoute(app: FastifyInstance) {
  app.get('/dev/login', { config: { rateLimit: apiRateLimit } }, async (request, reply) => {
    requireLocalDevAuth(request);
    const appCodeChallenge = validateAppCodeChallenge(
      (request.query as { app_code_challenge?: unknown }).app_code_challenge
    );
    reply.type('text/html').send(buildDevLoginHtml(config.devUniversityName, appCodeChallenge));
  });
}

function registerDevAuthorizeRoute(app: FastifyInstance, prisma: PrismaClient) {
  app.get('/dev/authorize', { config: { rateLimit: apiRateLimit } }, async (request, reply) => {
    requireLocalDevAuth(request);
    const role = (request.query as { role?: string }).role as 'student' | 'teacher' | undefined;
    if (!role || (role !== 'student' && role !== 'teacher')) {
      throw new ApiError(400, ErrorCodes.INVALID_ROLE, 'Invalid role');
    }
    const user = await upsertDevUser(prisma, role);
    const appCodeChallenge = validateAppCodeChallenge(
      (request.query as { app_code_challenge?: unknown }).app_code_challenge
    );
    const code = issueDevAuthCode(user.id, appCodeChallenge);
    const redirectUrl = new URL(config.devLoginCallbackUrl);
    redirectUrl.searchParams.set('code', code);
    reply.redirect(redirectUrl.toString());
  });
}

function registerDevIssueRoute(app: FastifyInstance, prisma: PrismaClient) {
  app.post('/dev/issue', { config: { rateLimit: apiRateLimit } }, async (request) => {
    requireLocalDevAuth(request);
    const body = parseDevIssueBody(request.body);
    const role =
      body.role === undefined
        ? 'student'
        : requireEnum(body.role, 'role', ['student', 'teacher'] as const);
    const userId = body.userId === undefined ? undefined : requireString(body.userId, 'userId');
    const user = userId
      ? await findExistingUser(prisma, userId)
      : await upsertDevUser(prisma, role);
    const appCodeChallenge =
      body.app_code_challenge === undefined
        ? undefined
        : validateAppCodeChallenge(body.app_code_challenge);
    return { code: issueDevAuthCode(user.id, appCodeChallenge) };
  });
}

function parseDevIssueBody(value: unknown): Record<string, unknown> {
  if (
    value !== undefined &&
    (typeof value !== 'object' || value === null || Array.isArray(value))
  ) {
    throw new ApiError(400, ErrorCodes.VALIDATION_ERROR, 'Invalid request body');
  }
  return (value ?? {}) as Record<string, unknown>;
}

function requireLocalDevAuth(request: FastifyRequest): void {
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
}

function isLoopbackAddress(ip: string | undefined): boolean {
  return ip === '127.0.0.1' || ip === '::1' || ip === '::ffff:127.0.0.1';
}

async function findExistingUser(prisma: PrismaClient, userId: string) {
  const user = await prisma.user.findUnique({ where: { id: userId } });
  if (!user) {
    throw new ApiError(404, ErrorCodes.USER_NOT_FOUND, 'User not found');
  }
  return user;
}

function buildDevLoginHtml(universityName: string, appCodeChallenge: string): string {
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
    '    <p>Resonance Local Demo Login</p>',
    '    <p>Select a persona to continue.</p>',
    '    <ul>',
    `<li><a href="/dev/authorize?role=student&app_code_challenge=${encodeURIComponent(appCodeChallenge)}">Login as Student Persona</a></li>`,
    `<li><a href="/dev/authorize?role=teacher&app_code_challenge=${encodeURIComponent(appCodeChallenge)}">Login as Teacher Persona</a></li>`,
    '    </ul>',
    '  </body>',
    '</html>',
  ].join('\n');
}

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}
