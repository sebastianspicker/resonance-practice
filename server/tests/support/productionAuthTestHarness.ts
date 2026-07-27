import { PrismaClient } from '@prisma/client';
import { afterAll, beforeAll, vi } from 'vitest';
import { buildIsolatedServer } from './isolatedServerHarness.js';

const productionAuthEnvironment = {
  AUTH_MODE: 'prod',
  HOST: '127.0.0.1',
  OIDC_DISCOVERY_URL: 'https://test.example.com/.well-known/openid-configuration',
  OIDC_CLIENT_ID: 'test-client',
  OIDC_CLIENT_SECRET: 'test-secret',
  OIDC_REDIRECT_URI: 'https://test.example.com/auth/callback',
  CORS_ORIGINS: 'https://test.example.com',
};

export function installProductionAuthTestServer() {
  let app: any;
  let prisma: PrismaClient;
  const originalEnvironment = new Map<string, string | undefined>();

  beforeAll(async () => {
    for (const [name, value] of Object.entries(productionAuthEnvironment)) {
      originalEnvironment.set(name, process.env[name]);
      process.env[name] = value;
    }

    ({ app, prisma } = await buildIsolatedServer());
  });

  afterAll(async () => {
    await app?.close();
    await prisma?.$disconnect();
    for (const [name, value] of originalEnvironment) {
      if (value === undefined) {
        delete process.env[name];
      } else {
        process.env[name] = value;
      }
    }
    vi.resetModules();
  });

  return {
    get app() {
      return app;
    },
  };
}
