// Proves development authentication rejects non-loopback callers even when explicitly enabled.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { PrismaClient } from '@prisma/client';
import { buildIsolatedServer } from './support/isolatedServerHarness.js';

describe('dev auth localhost restriction', () => {
  let app: any;
  let prisma: PrismaClient;
  let originalAuthMode: string | undefined;
  let originalDevUniversityName: string | undefined;

  beforeAll(async () => {
    originalAuthMode = process.env.AUTH_MODE;
    originalDevUniversityName = process.env.DEV_UNIVERSITY_NAME;
    process.env.AUTH_MODE = 'dev';
    process.env.DEV_UNIVERSITY_NAME = `T&T <Studio> "North" 'A'`;

    ({ app, prisma } = await buildIsolatedServer());
  });

  afterAll(async () => {
    await app.close();
    await prisma.$disconnect();
    process.env.AUTH_MODE = originalAuthMode;
    process.env.DEV_UNIVERSITY_NAME = originalDevUniversityName;
  });

  it('allows localhost for dev auth routes', async () => {
    const res = await app.inject({
      method: 'GET',
      url: '/dev/login',
      remoteAddress: '127.0.0.1',
    });
    expect(res.statusCode).toBe(200);
  });

  it('escapes the configured university name in the dev login HTML', async () => {
    const res = await app.inject({
      method: 'GET',
      url: '/dev/login',
      remoteAddress: '127.0.0.1',
    });
    const html = res.body;

    expect(res.statusCode).toBe(200);
    expect(res.headers['content-type']).toContain('text/html');
    expect(html).toContain('T&amp;T &lt;Studio&gt; &quot;North&quot; &#39;A&#39;');
    expect(html).not.toContain(`T&T <Studio> "North" 'A'`);
  });

  it('redirects localhost app login to dev login', async () => {
    const res = await app.inject({
      method: 'GET',
      url: '/auth/login',
      remoteAddress: '127.0.0.1',
    });
    expect(res.statusCode).toBe(302);
    expect(res.headers.location).toBe('/dev/login');
  });

  it('blocks non-local addresses for dev auth routes', async () => {
    const res = await app.inject({
      method: 'GET',
      url: '/dev/login',
      remoteAddress: '10.22.33.44',
    });
    expect(res.statusCode).toBe(403);
    expect(res.json().error?.code).toBe('DEV_AUTH_LOCAL_ONLY');
  });

  it('blocks non-local addresses for app login in dev mode', async () => {
    const res = await app.inject({
      method: 'GET',
      url: '/auth/login',
      remoteAddress: '10.22.33.44',
    });
    expect(res.statusCode).toBe(403);
    expect(res.json().error?.code).toBe('DEV_AUTH_LOCAL_ONLY');
  });

  it('rejects invalid roles on /dev/issue', async () => {
    const res = await app.inject({
      method: 'POST',
      url: '/dev/issue',
      remoteAddress: '127.0.0.1',
      payload: { role: 'admin' },
    });
    expect(res.statusCode).toBe(400);
    expect(res.json().error?.code).toBe('VALIDATION_ERROR');
  });
});
