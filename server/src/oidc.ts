/**
 * OIDC client setup and production auth code management.
 *
 * The OIDC client is initialised lazily on first use via `getOidcClient()`.
 * It uses OpenID Connect discovery (RFC 8414) to load the IdP metadata from
 * the configured `OIDC_DISCOVERY_URL`.
 *
 * Prod auth codes (issued by /auth/oidc/callback, consumed by /auth/session)
 * are short-lived single-use tokens stored in-memory — mirroring the dev auth
 * code mechanism but kept separate for clarity.
 */
import { Issuer, type Client } from 'openid-client';
import { nanoid } from 'nanoid';
import { oidcConfig } from './config.js';

// ── Prod auth code store ─────────────────────────────────────────────────────

const prodAuthCodes = new Map<string, { userId: string; expiresAt: number }>();

const PROD_CODE_TTL_MS = 5 * 60 * 1000; // 5 minutes

export function issueProdAuthCode(userId: string): string {
  // Evict expired entries before issuing a new code.
  const now = Date.now();
  for (const [k, v] of prodAuthCodes) {
    if (v.expiresAt < now) prodAuthCodes.delete(k);
  }
  const code = `prod_${nanoid(24)}`;
  prodAuthCodes.set(code, { userId, expiresAt: now + PROD_CODE_TTL_MS });
  return code;
}

export function consumeProdAuthCode(code: string): string | null {
  const record = prodAuthCodes.get(code);
  if (!record) return null;
  prodAuthCodes.delete(code);
  if (record.expiresAt < Date.now()) return null;
  return record.userId;
}

// ── OIDC state store (CSRF protection) ──────────────────────────────────────

const oidcStates = new Map<string, { expiresAt: number }>();

const STATE_TTL_MS = 10 * 60 * 1000; // 10 minutes

export function issueOidcState(): string {
  const now = Date.now();
  for (const [k, v] of oidcStates) {
    if (v.expiresAt < now) oidcStates.delete(k);
  }
  const state = nanoid(32);
  oidcStates.set(state, { expiresAt: now + STATE_TTL_MS });
  return state;
}

export function consumeOidcState(state: string): boolean {
  const record = oidcStates.get(state);
  if (!record) return false;
  oidcStates.delete(state);
  return record.expiresAt >= Date.now();
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
