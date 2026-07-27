// Isolates environment-driven configuration loading so module caching cannot hide invalid values.
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
  NODE_ENV: 'test',
  AUTH_MODE: 'dev',
  HOST: '127.0.0.1',
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
function runConfigWithEnv(
  overrides: Record<string, string | undefined>,
  script = `import '${serverDir}/src/config.ts'`
): { stdout: string; stderr: string } {
  const env: Record<string, string> = { ...baseEnv };
  for (const [key, value] of Object.entries(overrides)) {
    if (value === undefined) {
      delete env[key];
    } else {
      env[key] = value;
    }
  }

  // Load tsx through Node so this subprocess does not create the IPC listener
  // used by the tsx CLI. The test only needs TypeScript module loading.
  try {
    const stdout = execFileSync(process.execPath, ['--import', 'tsx', '--eval', script], {
      env,
      cwd: serverDir,
      stdio: ['pipe', 'pipe', 'pipe'],
      timeout: 10000,
    });
    return { stdout: stdout.toString(), stderr: '' };
  } catch (err: unknown) {
    const execErr = err as { stdout?: Buffer; stderr?: Buffer };
    return {
      stdout: execErr.stdout?.toString() ?? '',
      stderr: execErr.stderr?.toString() ?? (err as Error).message,
    };
  }
}

function importConfigWithEnv(overrides: Record<string, string | undefined>): string {
  return runConfigWithEnv(overrides).stderr;
}

describe('config top-level validation (subprocess)', () => {
  it('rejects JWT_SECRET shorter than 32 characters', () => {
    const stderr = importConfigWithEnv({ JWT_SECRET: 'short' });
    expect(stderr).toContain('JWT_SECRET must be at least 32 characters long');
  });

  it('rejects non-numeric PORT', () => {
    const stderr = importConfigWithEnv({ PORT: 'abc' });
    expect(stderr).toContain('PORT must be an integer between 1 and 65535');
  });

  it.each(['Infinity', '-Infinity', '12.5', '0', '65536'])(
    'rejects invalid PORT value %s',
    (PORT) => {
      const stderr = importConfigWithEnv({ PORT });
      expect(stderr).toContain('PORT must be an integer between 1 and 65535');
    }
  );

  it.each([
    ['ACCESS_TOKEN_TTL_MINUTES', 'Infinity'],
    ['REFRESH_TOKEN_TTL_DAYS', '-Infinity'],
    ['S3_PRESIGN_TTL_SECONDS', 'Infinity'],
    ['DEPENDENCY_TIMEOUT_MS', 'Infinity'],
  ])('rejects non-finite %s', (name, value) => {
    const stderr = importConfigWithEnv({ [name]: value });
    expect(stderr).toContain(
      name === 'S3_PRESIGN_TTL_SECONDS'
        ? 'integer between 1 and 604800'
        : name === 'DEPENDENCY_TIMEOUT_MS'
          ? 'integer between 100 and 300000'
          : 'positive integer'
    );
  });

  it('rejects NaN ACCESS_TOKEN_TTL_MINUTES', () => {
    const stderr = importConfigWithEnv({ ACCESS_TOKEN_TTL_MINUTES: 'not-a-number' });
    expect(stderr).toContain('ACCESS_TOKEN_TTL_MINUTES must be a positive integer');
  });

  it('rejects zero ACCESS_TOKEN_TTL_MINUTES', () => {
    const stderr = importConfigWithEnv({ ACCESS_TOKEN_TTL_MINUTES: '0' });
    expect(stderr).toContain('ACCESS_TOKEN_TTL_MINUTES must be a positive integer');
  });

  it('rejects negative ACCESS_TOKEN_TTL_MINUTES', () => {
    const stderr = importConfigWithEnv({ ACCESS_TOKEN_TTL_MINUTES: '-5' });
    expect(stderr).toContain('ACCESS_TOKEN_TTL_MINUTES must be a positive integer');
  });

  it('rejects NaN REFRESH_TOKEN_TTL_DAYS', () => {
    const stderr = importConfigWithEnv({ REFRESH_TOKEN_TTL_DAYS: 'nope' });
    expect(stderr).toContain('REFRESH_TOKEN_TTL_DAYS must be a positive integer');
  });

  it('rejects zero REFRESH_TOKEN_TTL_DAYS', () => {
    const stderr = importConfigWithEnv({ REFRESH_TOKEN_TTL_DAYS: '0' });
    expect(stderr).toContain('REFRESH_TOKEN_TTL_DAYS must be a positive integer');
  });

  it('rejects negative REFRESH_TOKEN_TTL_DAYS', () => {
    const stderr = importConfigWithEnv({ REFRESH_TOKEN_TTL_DAYS: '-1' });
    expect(stderr).toContain('REFRESH_TOKEN_TTL_DAYS must be a positive integer');
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

  it('rejects an external listener in development mode', () => {
    const stderr = importConfigWithEnv({ HOST: '0.0.0.0' });
    expect(stderr).toContain('AUTH_MODE=dev requires HOST to be a loopback address');
  });

  it('defaults an omitted development HOST to the IPv4 loopback address', () => {
    const script =
      `const { config } = await import('${serverDir}/src/config.ts'); ` +
      'process.stdout.write(config.host)';
    const result = runConfigWithEnv({ HOST: undefined }, script);
    expect(result.stderr).toBe('');
    expect(result.stdout).toBe('127.0.0.1');
  });

  it('requires an explicit production listener', () => {
    const stderr = importConfigWithEnv({
      AUTH_MODE: 'prod',
      HOST: undefined,
      CORS_ORIGINS: 'https://app.example.test',
      OIDC_DISCOVERY_URL: 'https://idp.example.test/.well-known/openid-configuration',
      OIDC_CLIENT_ID: 'client',
      OIDC_CLIENT_SECRET: 'secret',
      OIDC_REDIRECT_URI: 'https://api.example.test/auth/oidc/callback',
    });
    expect(stderr).toContain('AUTH_MODE=prod requires HOST to be set explicitly');
  });

  it('rejects missing JWT_SECRET', () => {
    const stderr = importConfigWithEnv({ JWT_SECRET: undefined });
    expect(stderr).toContain('Missing environment variable: JWT_SECRET');
  });

  it('rejects non-positive S3 presign TTL values', () => {
    const stderr = importConfigWithEnv({ S3_PRESIGN_TTL_SECONDS: '0' });
    expect(stderr).toContain('S3_PRESIGN_TTL_SECONDS must be an integer between 1 and 604800');
  });

  it.each([
    ['ACCESS_TOKEN_TTL_MINUTES', '1.5'],
    ['REFRESH_TOKEN_TTL_DAYS', '2.5'],
    ['S3_PRESIGN_TTL_SECONDS', '1.5'],
    ['S3_PRESIGN_TTL_SECONDS', '604801'],
  ])('rejects out-of-contract %s value %s', (name, value) => {
    const stderr = importConfigWithEnv({ [name]: value });
    expect(stderr).toContain(
      name === 'S3_PRESIGN_TTL_SECONDS' ? 'integer between 1 and 604800' : 'positive integer'
    );
  });

  it('rejects invalid S3_FORCE_PATH_STYLE booleans', () => {
    const stderr = importConfigWithEnv({ S3_FORCE_PATH_STYLE: 'tru' });
    expect(stderr).toContain('S3_FORCE_PATH_STYLE must be "true" or "false"');
  });

  it.each(['0', '99', '1.5', '300001'])(
    'rejects out-of-contract dependency timeout %s',
    (DEPENDENCY_TIMEOUT_MS) => {
      const stderr = importConfigWithEnv({ DEPENDENCY_TIMEOUT_MS });
      expect(stderr).toContain('DEPENDENCY_TIMEOUT_MS must be an integer between 100 and 300000');
    }
  );

  it('rejects JWT_REFRESH_SECRET shorter than 32 characters', () => {
    const stderr = importConfigWithEnv({ JWT_REFRESH_SECRET: 'short-refresh-secret' });
    expect(stderr).toContain('JWT_REFRESH_SECRET must be at least 32 characters');
  });

  it('rejects production mode without CORS_ORIGINS', () => {
    const stderr = importConfigWithEnv({
      AUTH_MODE: 'prod',
      HOST: '0.0.0.0',
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
      HOST: '0.0.0.0',
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
