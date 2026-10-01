/** Startup-negative cases for production transport and signing-key hardening. */
import { execFileSync } from 'node:child_process';
import { describe, expect, it } from 'vitest';

const baseEnv = {
  AUTH_MODE: 'prod',
  HOST: 'api.example.test',
  JWT_SECRET: '7CEJz64W6aZH2IZcJNMczrQKxHmfDZc2hJ9e5Jp8BaQ=',
  JWT_REFRESH_SECRET: 'R0LxQ1M8oVUXvmD6o1KxZ0P5b9JsL3T4Nq2fC8wYh6A=',
  S3_ENDPOINT: 'https://s3.example.test',
  S3_BUCKET: 'resonance',
  S3_ACCESS_KEY: 'access',
  S3_SECRET_KEY: 'secret',
  CORS_ORIGINS: 'https://app.example.test',
  OIDC_DISCOVERY_URL: 'https://issuer.example.test/.well-known/openid-configuration',
  OIDC_CLIENT_ID: 'resonance',
  OIDC_CLIENT_SECRET: 'test-client-secret',
  OIDC_REDIRECT_URI: 'https://api.example.test/auth/oidc/callback',
};

function loadProductionConfig(overrides: Record<string, string>) {
  try {
    execFileSync(
      process.execPath,
      [
        '--import',
        'tsx',
        '--input-type=module',
        '--eval',
        "await import('./src/platform/config.ts')",
      ],
      {
        cwd: process.cwd(),
        env: { ...process.env, ...baseEnv, ...overrides, NODE_ENV: 'test' },
        encoding: 'utf8',
        stdio: 'pipe',
      }
    );
    return '';
  } catch (error) {
    return `${(error as { stdout?: string }).stdout ?? ''}${(error as { stderr?: string }).stderr ?? ''}`;
  }
}

describe('production configuration', () => {
  it('rejects an implicit or duplicated refresh signing secret', () => {
    expect(loadProductionConfig({ JWT_REFRESH_SECRET: '' })).toContain(
      'Missing environment variable: JWT_REFRESH_SECRET'
    );
    expect(loadProductionConfig({ JWT_REFRESH_SECRET: baseEnv.JWT_SECRET })).toContain(
      'JWT_REFRESH_SECRET must be distinct from JWT_SECRET'
    );
  });

  it.each([
    ['JWT_SECRET', 'CHANGE-ME-generate-a-real-secret-at-least-32-chars'],
    ['JWT_SECRET', ` ${baseEnv.JWT_SECRET}`],
    ['JWT_SECRET', 'a'.repeat(44)],
    ['JWT_REFRESH_SECRET', 'short-secret'],
  ])('rejects weak production signing material: %s', (name, value) => {
    expect(loadProductionConfig({ [name]: value })).toContain(name);
  });

  it('rejects non-loopback HTTP OIDC and object-storage endpoints', () => {
    expect(
      loadProductionConfig({ OIDC_DISCOVERY_URL: 'http://issuer.example.test/openid' })
    ).toContain('OIDC_DISCOVERY_URL must use HTTPS');
    expect(loadProductionConfig({ S3_ENDPOINT: 'http://s3.example.test' })).toContain(
      'S3_ENDPOINT must use HTTPS'
    );
  });
});
