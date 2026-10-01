import type { PrismaClient } from '@prisma/client';
import crypto from 'node:crypto';
import type { FastifyInstance } from 'fastify';
import { config, oidcConfig } from '../../../../platform/config.js';
import { ErrorCodes } from '../../../../platform/http/errorCodes.js';
import { ApiError } from '../../../../platform/http/errors.js';
import {
  consumeOidcAttempt,
  displayNameFromClaims,
  getOidcClient,
  issueOidcAttempt,
  issueProdAuthCode,
  roleFromClaims,
  resolveIssuerScopedIdentity,
} from '../../application/oidc.js';
import { validateAppCodeChallenge } from '../../application/auth.js';

export function registerOidcRoutes(app: FastifyInstance, prisma: PrismaClient) {
  app.get('/auth/oidc/login', async (request, reply) => {
    const client = await requireOidcClient();
    const appCodeChallenge = validateAppCodeChallenge(
      (request.query as { app_code_challenge?: unknown }).app_code_challenge
    );
    const attempt = await issueOidcAttempt(prisma, appCodeChallenge);
    const authorizationUrl = client.authorizationUrl({
      scope: oidcConfig!.scopes,
      state: attempt.state,
      nonce: attempt.nonce,
      code_challenge: codeChallenge(attempt.codeVerifier),
      code_challenge_method: 'S256',
    });
    reply.header('Set-Cookie', oidcAttemptCookie(attempt));
    reply.redirect(authorizationUrl);
  });

  app.get('/auth/oidc/callback', async (request, reply) => {
    const client = await requireOidcClient();
    const params = client.callbackParams(request.raw);
    const state = typeof params.state === 'string' ? params.state : undefined;
    const cookieAttempt = parseOidcAttemptCookie(request.headers.cookie);

    if (
      !state ||
      !cookieAttempt ||
      cookieAttempt.state !== state ||
      !(await consumeOidcAttempt(prisma, cookieAttempt))
    ) {
      throw new ApiError(
        400,
        ErrorCodes.VALIDATION_ERROR,
        'Invalid or expired OIDC state parameter'
      );
    }

    let tokenSet;
    try {
      tokenSet = await client.callback(oidcConfig!.redirectUri, params, {
        state,
        nonce: cookieAttempt.nonce,
        code_verifier: cookieAttempt.codeVerifier,
      });
    } catch (err) {
      request.log.warn({ err }, 'oidc_callback_failed');
      throw new ApiError(401, ErrorCodes.INVALID_CODE, 'OIDC token exchange failed');
    }

    const claims = tokenSet.claims();
    const sub = claims.sub;
    if (!sub) {
      throw new ApiError(401, ErrorCodes.INVALID_TOKEN, 'OIDC token missing sub claim');
    }

    const issuer = typeof claims.iss === 'string' ? claims.iss : undefined;
    if (!issuer) {
      throw new ApiError(401, ErrorCodes.INVALID_TOKEN, 'OIDC token missing issuer claim');
    }
    const displayName = displayNameFromClaims(claims as Record<string, unknown>);
    const globalRole = roleFromClaims(claims as Record<string, unknown>);
    const userId = await resolveIssuerScopedIdentity(prisma, issuer, sub, displayName, globalRole);

    const code = await issueProdAuthCode(prisma, userId, cookieAttempt.appCodeChallenge);

    // Redirect to the app's custom URL scheme with the internal code.
    // The iOS app registers resonance:// so ASWebAuthenticationSession captures this redirect.
    const appCallbackUrl = new URL(config.appRedirectUri);
    appCallbackUrl.searchParams.set('code', code);
    reply.header('Set-Cookie', clearOidcAttemptCookie());
    reply.redirect(appCallbackUrl.toString());
  });
}

type BrowserOidcAttempt = {
  state: string;
  nonce: string;
  codeVerifier: string;
  browserBinding: string;
  appCodeChallenge: string;
};

const OIDC_COOKIE = 'resonance_oidc_attempt';

function codeChallenge(verifier: string): string {
  return crypto.createHash('sha256').update(verifier).digest('base64url');
}

function oidcAttemptCookie(attempt: BrowserOidcAttempt): string {
  const encoded = Buffer.from(JSON.stringify(attempt)).toString('base64url');
  const signature = crypto
    .createHmac('sha256', oidcConfig!.clientSecret)
    .update(encoded)
    .digest('base64url');
  return `${OIDC_COOKIE}=${encoded}.${signature}; HttpOnly; SameSite=Lax; Path=/auth/oidc/callback; Max-Age=600${
    oidcConfig && oidcConfig.redirectUri.startsWith('https:') ? '; Secure' : ''
  }`;
}

function clearOidcAttemptCookie(): string {
  return `${OIDC_COOKIE}=; HttpOnly; SameSite=Lax; Path=/auth/oidc/callback; Max-Age=0`;
}

function parseOidcAttemptCookie(header: string | undefined): BrowserOidcAttempt | null {
  const value = header
    ?.split(';')
    .map((part) => part.trim().split('='))
    .find(([name]) => name === OIDC_COOKIE)?.[1];
  if (!value) return null;
  const [encoded, signature] = value.split('.');
  if (!encoded || !signature) return null;
  const expected = crypto
    .createHmac('sha256', oidcConfig!.clientSecret)
    .update(encoded)
    .digest('base64url');
  if (signature.length !== expected.length) return null;
  if (!crypto.timingSafeEqual(Buffer.from(signature), Buffer.from(expected))) return null;
  try {
    const parsed: unknown = JSON.parse(Buffer.from(encoded, 'base64url').toString('utf8'));
    if (!isBrowserOidcAttempt(parsed)) return null;
    return parsed;
  } catch {
    return null;
  }
}

function isBrowserOidcAttempt(value: unknown): value is BrowserOidcAttempt {
  if (!value || typeof value !== 'object') return false;
  const record = value as Record<string, unknown>;
  return ['state', 'nonce', 'codeVerifier', 'browserBinding', 'appCodeChallenge'].every(
    (key) => typeof record[key] === 'string' && record[key].length >= 20
  );
}

async function requireOidcClient() {
  if (!oidcConfig) {
    throw new ApiError(
      501,
      ErrorCodes.AUTH_NOT_CONFIGURED,
      'OIDC is not configured on this server'
    );
  }
  return getOidcClient();
}
