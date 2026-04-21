import dotenv from 'dotenv';

dotenv.config();

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing environment variable: ${name}`);
  }
  return value;
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
  s3: {
    endpoint: requireEnv('S3_ENDPOINT'),
    region: process.env.S3_REGION ?? 'us-east-1',
    bucket: requireEnv('S3_BUCKET'),
    accessKey: requireEnv('S3_ACCESS_KEY'),
    secretKey: requireEnv('S3_SECRET_KEY'),
    forcePathStyle: (process.env.S3_FORCE_PATH_STYLE ?? 'true') === 'true',
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
  appBaseUrl: process.env.APP_BASE_URL ?? 'http://localhost:4000',
  jwtRefreshSecret: process.env.JWT_REFRESH_SECRET ?? requireEnv('JWT_SECRET') + '-refresh',
};

if (config.jwtSecret.length < 32) {
  throw new Error('JWT_SECRET must be at least 32 characters long for security.');
}

if (Number.isNaN(config.port)) {
  throw new Error('PORT must be a valid number.');
}

if (Number.isNaN(config.accessTokenTtlMinutes) || config.accessTokenTtlMinutes <= 0) {
  throw new Error('ACCESS_TOKEN_TTL_MINUTES must be a positive number.');
}

if (Number.isNaN(config.refreshTokenTtlDays) || config.refreshTokenTtlDays <= 0) {
  throw new Error('REFRESH_TOKEN_TTL_DAYS must be a positive number.');
}

if (Number.isNaN(config.s3.presignTtlSeconds) || config.s3.presignTtlSeconds <= 0) {
  throw new Error('S3_PRESIGN_TTL_SECONDS must be positive');
}

if (config.jwtRefreshSecret.length < 32) {
  throw new Error('JWT_REFRESH_SECRET must be at least 32 characters');
}

if (config.authMode === 'prod' && config.corsOrigins.length === 0) {
  throw new Error('Production requires CORS_ORIGINS to be configured');
}

export const oidcConfig = (() => {
  const discoveryUrl = process.env.OIDC_DISCOVERY_URL;
  const clientId = process.env.OIDC_CLIENT_ID;
  const clientSecret = process.env.OIDC_CLIENT_SECRET;
  const redirectUri = process.env.OIDC_REDIRECT_URI;

  if (config.authMode === 'prod') {
    if (!discoveryUrl || !clientId || !clientSecret || !redirectUri) {
      throw new Error(
        'AUTH_MODE=prod requires OIDC_DISCOVERY_URL, OIDC_CLIENT_ID, OIDC_CLIENT_SECRET, and OIDC_REDIRECT_URI to be set.'
      );
    }
  }

  if (!discoveryUrl || !clientId || !clientSecret || !redirectUri) {
    return null;
  }

  return {
    discoveryUrl,
    clientId,
    clientSecret,
    redirectUri,
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
