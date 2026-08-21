import type { PrismaClient } from '@prisma/client';
import type { FastifyInstance } from 'fastify';
import { oidcConfig } from '../../config.js';
import { ErrorCodes } from '../../errorCodes.js';
import { ApiError } from '../../errors.js';
import {
  consumeOidcState,
  displayNameFromClaims,
  getOidcClient,
  issueOidcState,
  issueProdAuthCode,
  roleFromClaims,
  ssoUserId,
} from '../../oidc.js';

export function registerOidcRoutes(app: FastifyInstance, prisma: PrismaClient) {
  app.get('/auth/oidc/login', async (_request, reply) => {
    const client = await requireOidcClient();
    const state = await issueOidcState(prisma);
    const authorizationUrl = client.authorizationUrl({
      scope: oidcConfig!.scopes,
      state,
    });
    reply.redirect(authorizationUrl);
  });

  app.get('/auth/oidc/callback', async (request, reply) => {
    const client = await requireOidcClient();
    const params = client.callbackParams(request.raw);
    const state = typeof params.state === 'string' ? params.state : undefined;

    if (!state || !(await consumeOidcState(prisma, state))) {
      throw new ApiError(
        400,
        ErrorCodes.VALIDATION_ERROR,
        'Invalid or expired OIDC state parameter'
      );
    }

    let tokenSet;
    try {
      tokenSet = await client.oauthCallback(oidcConfig!.redirectUri, params, { state });
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

    const code = await issueProdAuthCode(prisma, userId);

    // Redirect to the app's custom URL scheme with the internal code.
    // The iOS app registers resonance:// so ASWebAuthenticationSession captures this redirect.
    const appCallbackUrl = new URL('resonance://auth-callback');
    appCallbackUrl.searchParams.set('code', code);
    reply.redirect(appCallbackUrl.toString());
  });
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
