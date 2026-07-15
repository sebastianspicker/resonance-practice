import dotenv from 'dotenv';

dotenv.config();

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing environment variable: ${name}`);
  }
  return value;
}

function booleanEnv(name: string, fallback: boolean): boolean {
  const value = process.env[name];
  if (value === undefined) return fallback;
  if (value === 'true') return true;
  if (value === 'false') return false;
  throw new Error(`${name} must be "true" or "false".`);
}

type OidcEnv = {
  discoveryUrl: string | undefined;
  clientId: string | undefined;
  clientSecret: string | undefined;
  redirectUri: string | undefined;
};

function readOidcEnv(): OidcEnv {
  return {
    discoveryUrl: process.env.OIDC_DISCOVERY_URL,
    clientId: process.env.OIDC_CLIENT_ID,
    clientSecret: process.env.OIDC_CLIENT_SECRET,
    redirectUri: process.env.OIDC_REDIRECT_URI,
  };
}

function hasCompleteOidcEnv(env: OidcEnv): env is {
  discoveryUrl: string;
  clientId: string;
  clientSecret: string;
  redirectUri: string;
} {
  return Boolean(env.discoveryUrl && env.clientId && env.clientSecret && env.redirectUri);
}

function requireProdOidcEnv(env: OidcEnv) {
  if (!hasCompleteOidcEnv(env)) {
    throw new Error(
      'AUTH_MODE=prod requires OIDC_DISCOVERY_URL, OIDC_CLIENT_ID, OIDC_CLIENT_SECRET, and OIDC_REDIRECT_URI to be set.'
    );
  }
}

/**
 * Validates that a dev login callback URL uses an allowed scheme.
 * Only `resonance://` (app custom scheme) and `http://localhost` are permitted.
 * Exported for testing.
 */
export function validateDevCallbackUrl(url: string): string {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    throw new Error(
      'DEV_LOGIN_CALLBACK_URL must start with "resonance://" or "http://localhost". ' +
        `Got: "${url}"`
    );
  }

  if (parsed.protocol === 'resonance:') {
    return url;
  }

  if (parsed.protocol === 'http:' && parsed.hostname === 'localhost') {
    return url;
  }

  throw new Error(
    'DEV_LOGIN_CALLBACK_URL must start with "resonance://" or "http://localhost". ' +
      `Got: "${url}"`
  );
}

export const config = {
  port: Number(process.env.PORT ?? 4000),
  authMode: (() => {
    const mode = process.env.AUTH_MODE ?? 'prod';
    if (mode !== 'dev' && mode !== 'prod') {
      throw new Error('AUTH_MODE must be "dev" or "prod"');
    }
    return mode;
  })(),
  jwtSecret: requireEnv('JWT_SECRET'),
  accessTokenTtlMinutes: Number(process.env.ACCESS_TOKEN_TTL_MINUTES ?? 15),
  refreshTokenTtlDays: Number(process.env.REFRESH_TOKEN_TTL_DAYS ?? 7),
  dependencyTimeoutMs: Number(process.env.DEPENDENCY_TIMEOUT_MS ?? 10_000),
  s3: {
    endpoint: requireEnv('S3_ENDPOINT'),
    region: process.env.S3_REGION ?? 'us-east-1',
    bucket: requireEnv('S3_BUCKET'),
    accessKey: requireEnv('S3_ACCESS_KEY'),
    secretKey: requireEnv('S3_SECRET_KEY'),
    forcePathStyle: booleanEnv('S3_FORCE_PATH_STYLE', true),
    presignTtlSeconds: Number(process.env.S3_PRESIGN_TTL_SECONDS ?? 900),
  },
  corsOrigins: (process.env.CORS_ORIGINS ?? '')
    .split(',')
    .map((origin) => origin.trim())
    .filter(Boolean),
  devUniversityName: process.env.DEV_UNIVERSITY_NAME ?? 'Mock University Conservatory',
  devLoginCallbackUrl: validateDevCallbackUrl(
    process.env.DEV_LOGIN_CALLBACK_URL ?? 'resonance://auth-callback'
  ),
  jwtRefreshSecret: process.env.JWT_REFRESH_SECRET ?? requireEnv('JWT_SECRET') + '-refresh',
};

if (config.jwtSecret.length < 32) {
  throw new Error('JWT_SECRET must be at least 32 characters long for security.');
}

if (
  !Number.isFinite(config.port) ||
  !Number.isInteger(config.port) ||
  config.port < 1 ||
  config.port > 65535
) {
  throw new Error('PORT must be an integer between 1 and 65535.');
}

if (
  !Number.isFinite(config.accessTokenTtlMinutes) ||
  !Number.isInteger(config.accessTokenTtlMinutes) ||
  config.accessTokenTtlMinutes <= 0
) {
  throw new Error('ACCESS_TOKEN_TTL_MINUTES must be a positive integer.');
}

if (
  !Number.isFinite(config.refreshTokenTtlDays) ||
  !Number.isInteger(config.refreshTokenTtlDays) ||
  config.refreshTokenTtlDays <= 0
) {
  throw new Error('REFRESH_TOKEN_TTL_DAYS must be a positive integer.');
}

if (
  !Number.isFinite(config.dependencyTimeoutMs) ||
  !Number.isInteger(config.dependencyTimeoutMs) ||
  config.dependencyTimeoutMs < 100 ||
  config.dependencyTimeoutMs > 300_000
) {
  throw new Error('DEPENDENCY_TIMEOUT_MS must be an integer between 100 and 300000.');
}

if (
  !Number.isFinite(config.s3.presignTtlSeconds) ||
  !Number.isInteger(config.s3.presignTtlSeconds) ||
  config.s3.presignTtlSeconds < 1 ||
  config.s3.presignTtlSeconds > 604_800
) {
  throw new Error('S3_PRESIGN_TTL_SECONDS must be an integer between 1 and 604800.');
}

if (config.jwtRefreshSecret.length < 32) {
  throw new Error('JWT_REFRESH_SECRET must be at least 32 characters');
}

if (config.authMode === 'prod' && config.corsOrigins.length === 0) {
  throw new Error('Production requires CORS_ORIGINS to be configured');
}

export const oidcConfig = (() => {
  const oidcEnv = readOidcEnv();

  if (config.authMode === 'prod') {
    requireProdOidcEnv(oidcEnv);
  }

  if (!hasCompleteOidcEnv(oidcEnv)) {
    return null;
  }

  return {
    discoveryUrl: oidcEnv.discoveryUrl,
    clientId: oidcEnv.clientId,
    clientSecret: oidcEnv.clientSecret,
    redirectUri: oidcEnv.redirectUri,
    /** OIDC claim name used to determine the user's role. Default: "role". */
    roleClaim: process.env.OIDC_ROLE_CLAIM ?? 'role',
    /** Claim value that maps to the teacher role. Default: "teacher". */
    teacherValue: process.env.OIDC_TEACHER_VALUE ?? 'teacher',
    /** Scopes to request from the IdP. */
    scopes: 'openid profile email',
  };
})();

/** Application limits — extracted from inline magic numbers. */
export const limits = {
  /** Maximum number of markers per feedback item */
  maxMarkers: 50,
  /** Maximum length of individual marker text */
  maxMarkerTextLength: 1000,
  /** HTTP body size limit in bytes (1 MB) */
  bodyLimitBytes: 1_048_576,
  /** Dev auth code time-to-live in milliseconds (5 minutes) */
  devAuthCodeTtlMs: 5 * 60 * 1000,
  /** Maximum duration in seconds for a practice entry or artifact (8 hours) */
  maxDurationSeconds: 28_800,
  /** Maximum number of tags per entry */
  maxTags: 30,
  /** Maximum length of a single tag string */
  maxTagLength: 100,
  /** Maximum length of commentsText in feedback */
  maxCommentsTextLength: 10_000,
  /** Maximum marker timeSeconds (8 hours) */
  maxMarkerTimeSeconds: 28_800,
  /** Maximum length of auth code string */
  maxAuthCodeLength: 2048,
  /** Rate-limit for auth endpoints: max requests per window */
  authRateLimitMax: 10,
  /** Rate-limit window for auth endpoints */
  authRateLimitWindow: '1 minute',
  /** Maximum upload size for a single artifact in bytes (100 MB) */
  maxUploadSizeBytes: 104_857_600,
} as const;
