// Establishes isolated test credentials, guarded database cleanup, and shared mock resets.
// ── Test-only credentials ───────────────────────────────────────────
// These values are exclusively for local/CI test runs.  They must
// NEVER be reused in staging or production environments.
// ────────────────────────────────────────────────────────────────────
process.env.JWT_SECRET = 'test-secret-at-least-32-characters';
process.env.ACCESS_TOKEN_TTL_MINUTES = '15';
process.env.REFRESH_TOKEN_TTL_DAYS = '7';
process.env.S3_ENDPOINT = 'http://localhost:9000';
process.env.S3_BUCKET = 'resonance-dev';
process.env.S3_ACCESS_KEY = 'minioadmin';
process.env.S3_SECRET_KEY = 'minioadmin';
process.env.S3_FORCE_PATH_STYLE = 'true';
process.env.S3_PRESIGN_TTL_SECONDS = '900';
process.env.AUTH_MODE = 'dev';
process.env.CORS_ORIGINS = '';
process.env.DEV_LOGIN_CALLBACK_URL = 'resonance://auth-callback';
process.env.DATABASE_URL =
  process.env.DATABASE_URL ?? 'postgresql://resonance:resonance@localhost:5432/resonance_test';

// Safety check: only allow explicit test databases.
const { assertTestDatabaseUrl } = await import('./support/databaseSafety.js');
try {
  assertTestDatabaseUrl(process.env.DATABASE_URL);
} catch (error) {
  console.error(`\n${(error as Error).message}`);
  process.exit(1);
}
