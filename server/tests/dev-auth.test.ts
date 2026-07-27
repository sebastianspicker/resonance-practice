// Covers the loopback-only development sign-in flow and its short-lived authorization codes.
import { describe, expect, it } from 'vitest';
import { installProductionAuthTestServer } from './support/productionAuthTestHarness.js';

describe('dev auth disabled', () => {
  const prodServer = installProductionAuthTestServer();

  it('returns 404 for dev login', async () => {
    const res = await prodServer.app.inject({ method: 'GET', url: '/dev/login' });
    expect(res.statusCode).toBe(404);
  });

  it('returns 404 for dev issue', async () => {
    const res = await prodServer.app.inject({
      method: 'POST',
      url: '/dev/issue',
      payload: { role: 'student' },
    });
    expect(res.statusCode).toBe(404);
  });

  it('redirects app login to the OIDC login route', async () => {
    const res = await prodServer.app.inject({ method: 'GET', url: '/auth/login' });
    expect(res.statusCode).toBe(302);
    expect(res.headers.location).toBe('/auth/oidc/login');
  });
});
