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
import { oidcConfig } from './config.js';

// ── Prod auth code store ─────────────────────────────────────────────────────

const PROD_CODE_TTL_MS = 5 * 60 * 1000; // 5 minutes

export async function issueProdAuthCode(prisma: PrismaClient, userId: string): Promise<string> {
  const code = `prod_${nanoid(24)}`;
  await createAuthFlowToken(prisma, 'prod_code', code, PROD_CODE_TTL_MS, userId);
  return code;
}

export async function consumeProdAuthCode(
  prisma: PrismaClient,
  code: string
): Promise<string | null> {
  const record = await consumeAuthFlowToken(prisma, 'prod_code', code);
  return record?.userId ?? null;
}

// ── OIDC state store (CSRF protection) ──────────────────────────────────────

const STATE_TTL_MS = 10 * 60 * 1000; // 10 minutes

export async function issueOidcState(prisma: PrismaClient): Promise<string> {
  const state = nanoid(32);
  await createAuthFlowToken(prisma, 'oidc_state', state, STATE_TTL_MS);
  return state;
}

export async function consumeOidcState(prisma: PrismaClient, state: string): Promise<boolean> {
  return (await consumeAuthFlowToken(prisma, 'oidc_state', state)) !== null;
}

function hashAuthFlowToken(token: string): string {
  return crypto.createHash('sha256').update(token).digest('hex');
}

async function createAuthFlowToken(
  prisma: PrismaClient,
  kind: AuthFlowTokenKind,
  token: string,
  ttlMs: number,
  userId?: string
) {
  const now = new Date();
  await prisma.$transaction(async (tx) => {
    await tx.authFlowToken.deleteMany({ where: { expiresAt: { lt: now } } });
    await tx.authFlowToken.create({
      data: {
        tokenHash: hashAuthFlowToken(token),
        kind,
        ...(userId ? { userId } : {}),
        expiresAt: new Date(now.getTime() + ttlMs),
      },
    });
  });
}

async function consumeAuthFlowToken(prisma: PrismaClient, kind: AuthFlowTokenKind, token: string) {
  const tokenHash = hashAuthFlowToken(token);
  const now = new Date();
  return prisma.$transaction(async (tx) => {
    const record = await tx.authFlowToken.findUnique({ where: { tokenHash } });
    if (!record || record.kind !== kind || record.expiresAt < now) {
      if (record) {
        await tx.authFlowToken.deleteMany({ where: { tokenHash } });
      }
      return null;
    }
    const consumed = await tx.authFlowToken.deleteMany({
      where: { tokenHash, kind, expiresAt: { gte: now } },
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

/** Reset cached client — used in tests only. */
export function _resetOidcClientForTesting() {
  _client = null;
}

// ── User identity helpers ────────────────────────────────────────────────────

/**
 * Derives the Resonance user ID from an OIDC subject claim.
 * Format: `sso:<sub>` — ensures no collision with dev IDs.
 */
export function ssoUserId(sub: string): string {
  return `sso:${sub}`;
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
