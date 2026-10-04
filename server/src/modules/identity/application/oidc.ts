/**
 * OIDC client setup and production auth code management.
 *
 * The OIDC client is initialised lazily on first use via `getOidcClient()`.
 * It uses OpenID Connect discovery (RFC 8414) to load the IdP metadata from
 * the configured `OIDC_DISCOVERY_URL`.
 *
 * Production OIDC state and app auth codes are stored as short-lived hashes in
 * PostgreSQL so login remains correct across multiple API replicas.
 */
import crypto from 'node:crypto';
import type { AuthFlowTokenKind, PrismaClient } from '@prisma/client';
import { Issuer, type Client } from 'openid-client';
import { nanoid } from 'nanoid';
import { oidcConfig } from '../../../platform/config.js';
import { s256CodeChallenge } from './auth.js';

// ── Prod auth code store ─────────────────────────────────────────────────────

const PROD_CODE_TTL_MS = 5 * 60 * 1000; // 5 minutes

export async function issueProdAuthCode(
  prisma: PrismaClient,
  userId: string,
  appCodeChallenge: string
): Promise<string> {
  const code = `prod_${nanoid(24)}`;
  await createAuthFlowToken(prisma, 'prod_code', code, PROD_CODE_TTL_MS, userId, {
    appCodeChallenge,
  });
  return code;
}

export async function consumeProdAuthCode(
  prisma: PrismaClient,
  code: string,
  codeVerifier: string
): Promise<string | null> {
  const record = await consumeAuthFlowToken(
    prisma,
    'prod_code',
    code,
    s256CodeChallenge(codeVerifier)
  );
  return record?.userId ?? null;
}

// ── OIDC state store (CSRF protection) ──────────────────────────────────────

const STATE_TTL_MS = 10 * 60 * 1000; // 10 minutes

export type OidcAttempt = {
  state: string;
  nonce: string;
  codeVerifier: string;
  browserBinding: string;
  appCodeChallenge: string;
};

/** Create a one-time authorization attempt whose secrets stay in a signed, HttpOnly browser cookie. */
export async function issueOidcAttempt(
  prisma: PrismaClient,
  appCodeChallenge: string
): Promise<OidcAttempt> {
  const attempt = {
    state: nanoid(32),
    nonce: nanoid(32),
    codeVerifier: crypto.randomBytes(32).toString('base64url'),
    browserBinding: crypto.randomBytes(32).toString('base64url'),
    appCodeChallenge,
  };
  await createAuthFlowToken(prisma, 'oidc_state', attempt.state, STATE_TTL_MS, undefined, {
    browserBindingHash: hashAuthFlowToken(attempt.browserBinding),
    nonceHash: hashAuthFlowToken(attempt.nonce),
    verifierHash: hashAuthFlowToken(attempt.codeVerifier),
    appCodeChallenge,
  });
  return attempt;
}

/** Atomically consume one attempt only when every browser-bound verifier matches. */
export async function consumeOidcAttempt(
  prisma: PrismaClient,
  attempt: OidcAttempt
): Promise<boolean> {
  const tokenHash = hashAuthFlowToken(attempt.state);
  const now = new Date();
  return prisma.$transaction(async (tx) => {
    const record = await tx.authFlowToken.findUnique({ where: { tokenHash } });
    const valid =
      record?.kind === 'oidc_state' &&
      record.expiresAt >= now &&
      record.browserBindingHash === hashAuthFlowToken(attempt.browserBinding) &&
      record.nonceHash === hashAuthFlowToken(attempt.nonce) &&
      record.verifierHash === hashAuthFlowToken(attempt.codeVerifier);
    if (!valid) return false;
    return (
      (await tx.authFlowToken.deleteMany({ where: { tokenHash, kind: 'oidc_state' } })).count === 1
    );
  });
}

function hashAuthFlowToken(token: string): string {
  return crypto.createHash('sha256').update(token).digest('hex');
}

/**
 * Persist only a hash of a short-lived OIDC state or app code so any replica
 * can validate it without storing the bearer value.
 */
async function createAuthFlowToken(
  prisma: PrismaClient,
  kind: AuthFlowTokenKind,
  token: string,
  ttlMs: number,
  userId?: string,
  metadata?: {
    browserBindingHash?: string;
    nonceHash?: string;
    verifierHash?: string;
    appCodeChallenge?: string;
  }
) {
  const now = new Date();
  await prisma.$transaction(async (tx) => {
    await tx.authFlowToken.deleteMany({ where: { expiresAt: { lt: now } } });
    await tx.authFlowToken.create({
      data: {
        tokenHash: hashAuthFlowToken(token),
        kind,
        ...(userId ? { userId } : {}),
        ...(metadata ?? {}),
        expiresAt: new Date(now.getTime() + ttlMs),
      },
    });
  });
}

/** Atomically delete one matching unexpired token so concurrent consumers cannot replay it. */
async function consumeAuthFlowToken(
  prisma: PrismaClient,
  kind: AuthFlowTokenKind,
  token: string,
  appCodeChallenge?: string
) {
  const tokenHash = hashAuthFlowToken(token);
  const now = new Date();
  return prisma.$transaction(async (tx) => {
    const record = await tx.authFlowToken.findUnique({ where: { tokenHash } });
    if (!record || record.kind !== kind) return null;
    if (record.expiresAt < now) {
      if (record) {
        await tx.authFlowToken.deleteMany({ where: { tokenHash } });
      }
      return null;
    }
    if (appCodeChallenge !== undefined && record.appCodeChallenge !== appCodeChallenge) return null;
    const consumed = await tx.authFlowToken.deleteMany({
      where: {
        tokenHash,
        kind,
        expiresAt: { gte: now },
        ...(appCodeChallenge === undefined ? {} : { appCodeChallenge }),
      },
    });
    return consumed.count === 1 ? record : null;
  });
}

// ── OIDC client (lazy) ───────────────────────────────────────────────────────

let _client: Client | null = null;

/**
 * Returns an initialised openid-client Client via OIDC discovery.
 * The result is cached after the first successful initialisation.
 * Throws if OIDC is not configured.
 */
export async function getOidcClient(): Promise<Client> {
  if (_client) return _client;

  if (!oidcConfig) {
    throw new Error(
      'OIDC is not configured. Set OIDC_DISCOVERY_URL, OIDC_CLIENT_ID, OIDC_CLIENT_SECRET, and OIDC_REDIRECT_URI.'
    );
  }

  const issuer = await Issuer.discover(oidcConfig.discoveryUrl);
  _client = new issuer.Client({
    client_id: oidcConfig.clientId,
    client_secret: oidcConfig.clientSecret,
    redirect_uris: [oidcConfig.redirectUri],
    response_types: ['code'],
  });

  return _client;
}

// ── User identity helpers ────────────────────────────────────────────────────

/** Stable internal IDs derive from issuer and subject without exposing either in user IDs. */
function issuerScopedSsoUserId(issuer: string, subject: string): string {
  return `sso:${crypto.createHash('sha256').update(`${issuer}\u0000${subject}`).digest('base64url').slice(0, 32)}`;
}

/** Resolve a token identity without ever treating an OIDC subject as globally unique. */
export async function resolveIssuerScopedIdentity(
  prisma: PrismaClient,
  issuer: string,
  subject: string,
  displayName: string,
  globalRole: 'student' | 'teacher'
): Promise<string> {
  const existing = await prisma.externalIdentity.findUnique({
    where: { issuer_subject: { issuer, subject } },
  });
  if (existing) {
    await prisma.user.update({ where: { id: existing.userId }, data: { displayName, globalRole } });
    return existing.userId;
  }

  const userId = issuerScopedSsoUserId(issuer, subject);
  await prisma.user.upsert({
    where: { id: userId },
    update: { displayName, globalRole },
    create: { id: userId, displayName, globalRole },
  });
  await prisma.externalIdentity.create({ data: { issuer, subject, userId } });
  return userId;
}

/**
 * Derives a GlobalRole from OIDC token claims.
 * Checks `oidcConfig.roleClaim` against `oidcConfig.teacherValue`.
 * Defaults to 'student' if the claim is absent or has a different value.
 */
export function roleFromClaims(claims: Record<string, unknown>): 'student' | 'teacher' {
  if (!oidcConfig) return 'student';
  const claimValue = claims[oidcConfig.roleClaim];
  return claimValue === oidcConfig.teacherValue ? 'teacher' : 'student';
}

/**
 * Derives a display name from OIDC token claims.
 * Priority: name > preferred_username > email > sub.
 */
export function displayNameFromClaims(claims: Record<string, unknown>): string {
  for (const key of ['name', 'preferred_username', 'email', 'sub']) {
    const v = claims[key];
    if (typeof v === 'string' && v.trim()) return v.trim();
  }
  return 'Unknown User';
}
