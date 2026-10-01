/** Native-app PKCE code exchange at POST /auth/session: success and every rejection path. */
import request from 'supertest';
import { describe, expect, it } from 'vitest';
import { s256CodeChallenge } from '../src/modules/identity/application/auth.js';
import { app, installBasicSuite } from './support/testUtils.js';

const verifier = 'v'.repeat(43);
const redirectUri = 'resonance://auth-callback';

async function issueCode(): Promise<string> {
  const issued = await request(app.server)
    .post('/dev/issue')
    .send({ userId: 'student-1', app_code_challenge: s256CodeChallenge(verifier) });
  return issued.body.code as string;
}

const exchange = (body: Record<string, unknown>) =>
  request(app.server).post('/auth/session').send(body);

describe('POST /auth/session PKCE exchange', () => {
  installBasicSuite();

  it('issues tokens and the user for a matching verifier and redirect URI', async () => {
    const response = await exchange({
      code: await issueCode(),
      codeVerifier: verifier,
      redirectUri,
    });
    expect(response.status).toBe(201);
    expect(response.body).toMatchObject({
      accessToken: expect.any(String),
      refreshToken: expect.any(String),
      user: { id: 'student-1', displayName: 'Student', globalRole: 'student' },
    });
  });

  it('rejects a wrong verifier and burns the code for the correct one', async () => {
    const code = await issueCode();
    const wrong = await exchange({ code, codeVerifier: 'w'.repeat(43), redirectUri });
    expect(wrong.status).toBe(401);
    expect(wrong.body.error).toMatchObject({ code: 'INVALID_CODE' });

    const retry = await exchange({ code, codeVerifier: verifier, redirectUri });
    expect(retry.status).toBe(401);
    expect(retry.body.error).toMatchObject({ code: 'INVALID_CODE' });
  });

  it('rejects a redirect URI that differs from the configured one', async () => {
    const response = await exchange({
      code: await issueCode(),
      codeVerifier: verifier,
      redirectUri: 'resonance://evil-callback',
    });
    expect(response.status).toBe(400);
    expect(response.body.error).toMatchObject({
      code: 'VALIDATION_ERROR',
      message: 'Invalid redirectUri',
    });
  });

  it('rejects reuse of a code that was already exchanged', async () => {
    const code = await issueCode();
    const first = await exchange({ code, codeVerifier: verifier, redirectUri });
    expect(first.status).toBe(201);
    const reuse = await exchange({ code, codeVerifier: verifier, redirectUri });
    expect(reuse.status).toBe(401);
    expect(reuse.body.error).toMatchObject({ code: 'INVALID_CODE' });
    expect(reuse.body.accessToken).toBeUndefined();
  });

  it.each([
    ['code', { codeVerifier: verifier, redirectUri }],
    ['codeVerifier', { code: 'dev_placeholder', redirectUri }],
    ['redirectUri', { code: 'dev_placeholder', codeVerifier: verifier }],
  ])('rejects a request missing %s with 400', async (_field, body) => {
    const response = await exchange(body);
    expect(response.status).toBe(400);
    expect(response.body.error).toMatchObject({ code: 'VALIDATION_ERROR' });
  });
});
