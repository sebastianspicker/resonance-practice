import { describe, expect, it } from 'vitest';
import { execFileSync } from 'child_process';
import path from 'path';

/**
 * Tests for config.ts top-level validation errors by spawning Node subprocesses
 * with invalid environment variables. This is the only reliable way to test
 * module-level validation in ESM, since Node caches module evaluations.
 */

const serverDir = path.resolve(import.meta.dirname, '..');

/** Base environment variables needed for config.ts to load */
const baseEnv: Record<string, string> = {
  JWT_SECRET: 'test-secret-at-least-32-characters',
  AUTH_MODE: 'dev',
  S3_ENDPOINT: 'http://localhost:9000',
  S3_BUCKET: 'test-bucket',
  S3_ACCESS_KEY: 'minioadmin',
  S3_SECRET_KEY: 'minioadmin',
  DEV_LOGIN_CALLBACK_URL: 'resonance://auth-callback',
  PORT: '4000',
  ACCESS_TOKEN_TTL_MINUTES: '15',
  REFRESH_TOKEN_TTL_DAYS: '7',
  // Needed for Node + tsx
  PATH: process.env.PATH!,
  HOME: process.env.HOME!,
};

/**
 * Try to import config.ts with the given env overrides in a subprocess.
 * Returns the stderr output.
 */
function importConfigWithEnv(overrides: Record<string, string | undefined>): string {
  const env: Record<string, string> = { ...baseEnv };
  for (const [key, value] of Object.entries(overrides)) {
    if (value === undefined) {
      delete env[key];
    } else {
      env[key] = value;
    }
  }

  // Use tsx to run a tiny script that imports config.ts
  const script = `import '${serverDir}/src/config.ts'`;

  try {
    execFileSync(path.resolve(serverDir, 'node_modules/.bin/tsx'), ['--eval', script], {
      env,
      cwd: serverDir,
      stdio: ['pipe', 'pipe', 'pipe'],
      timeout: 10000,
    });
    return ''; // No error
  } catch (err: unknown) {
    const execErr = err as { stderr?: Buffer };
    return execErr.stderr?.toString() ?? (err as Error).message;
  }
}

describe('config top-level validation (subprocess)', () => {
  it('rejects JWT_SECRET shorter than 32 characters', () => {
    const stderr = importConfigWithEnv({ JWT_SECRET: 'short' });
    expect(stderr).toContain('JWT_SECRET must be at least 32 characters long');
  });

  it('rejects non-numeric PORT', () => {
    const stderr = importConfigWithEnv({ PORT: 'abc' });
    expect(stderr).toContain('PORT must be a valid number');
  });

  it('rejects NaN ACCESS_TOKEN_TTL_MINUTES', () => {
    const stderr = importConfigWithEnv({ ACCESS_TOKEN_TTL_MINUTES: 'not-a-number' });
    expect(stderr).toContain('ACCESS_TOKEN_TTL_MINUTES must be a positive number');
  });

  it('rejects zero ACCESS_TOKEN_TTL_MINUTES', () => {
    const stderr = importConfigWithEnv({ ACCESS_TOKEN_TTL_MINUTES: '0' });
    expect(stderr).toContain('ACCESS_TOKEN_TTL_MINUTES must be a positive number');
  });

  it('rejects negative ACCESS_TOKEN_TTL_MINUTES', () => {
    const stderr = importConfigWithEnv({ ACCESS_TOKEN_TTL_MINUTES: '-5' });
    expect(stderr).toContain('ACCESS_TOKEN_TTL_MINUTES must be a positive number');
  });

  it('rejects NaN REFRESH_TOKEN_TTL_DAYS', () => {
    const stderr = importConfigWithEnv({ REFRESH_TOKEN_TTL_DAYS: 'nope' });
    expect(stderr).toContain('REFRESH_TOKEN_TTL_DAYS must be a positive number');
  });

  it('rejects zero REFRESH_TOKEN_TTL_DAYS', () => {
    const stderr = importConfigWithEnv({ REFRESH_TOKEN_TTL_DAYS: '0' });
    expect(stderr).toContain('REFRESH_TOKEN_TTL_DAYS must be a positive number');
  });

  it('rejects negative REFRESH_TOKEN_TTL_DAYS', () => {
    const stderr = importConfigWithEnv({ REFRESH_TOKEN_TTL_DAYS: '-1' });
    expect(stderr).toContain('REFRESH_TOKEN_TTL_DAYS must be a positive number');
  });

  it('rejects DEV_LOGIN_CALLBACK_URL with bad scheme', () => {
    const stderr = importConfigWithEnv({ DEV_LOGIN_CALLBACK_URL: 'https://evil.com' });
    expect(stderr).toContain(
      'DEV_LOGIN_CALLBACK_URL must start with "resonance://" or "http://localhost"'
    );
  });

  it('rejects invalid AUTH_MODE', () => {
    const stderr = importConfigWithEnv({ AUTH_MODE: 'staging' });
    expect(stderr).toContain('AUTH_MODE must be "dev" or "prod"');
  });

  it('rejects missing JWT_SECRET', () => {
    const stderr = importConfigWithEnv({ JWT_SECRET: undefined });
    expect(stderr).toContain('Missing environment variable: JWT_SECRET');
  });

  it('rejects non-positive S3 presign TTL values', () => {
    const stderr = importConfigWithEnv({ S3_PRESIGN_TTL_SECONDS: '0' });
    expect(stderr).toContain('S3_PRESIGN_TTL_SECONDS must be positive');
  });

  it('rejects JWT_REFRESH_SECRET shorter than 32 characters', () => {
    const stderr = importConfigWithEnv({ JWT_REFRESH_SECRET: 'short-refresh-secret' });
    expect(stderr).toContain('JWT_REFRESH_SECRET must be at least 32 characters');
  });

  it('rejects production mode without CORS_ORIGINS', () => {
    const stderr = importConfigWithEnv({
      AUTH_MODE: 'prod',
      CORS_ORIGINS: undefined,
      OIDC_DISCOVERY_URL: 'https://idp.example.test/.well-known/openid-configuration',
      OIDC_CLIENT_ID: 'client',
      OIDC_CLIENT_SECRET: 'secret',
      OIDC_REDIRECT_URI: 'https://api.example.test/auth/oidc/callback',
    });
    expect(stderr).toContain('Production requires CORS_ORIGINS to be configured');
  });

  it('rejects production mode without complete OIDC configuration', () => {
    const stderr = importConfigWithEnv({
      AUTH_MODE: 'prod',
      CORS_ORIGINS: 'https://app.example.test',
      OIDC_DISCOVERY_URL: 'https://idp.example.test/.well-known/openid-configuration',
      OIDC_CLIENT_ID: 'client',
      OIDC_CLIENT_SECRET: undefined,
      OIDC_REDIRECT_URI: 'https://api.example.test/auth/oidc/callback',
    });
    expect(stderr).toContain(
      'AUTH_MODE=prod requires OIDC_DISCOVERY_URL, OIDC_CLIENT_ID, OIDC_CLIENT_SECRET, and OIDC_REDIRECT_URI to be set.'
    );
  });
});
