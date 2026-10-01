// Opens a development session over HTTP and returns the complete token response.
import { createHash } from 'node:crypto';
import request from 'supertest';
import { app, type TestRole } from './testUtils.js';

const codeVerifier = 'b'.repeat(43);

export async function openSession(userId: string, role: TestRole) {
  const issue = await request(app.server)
    .post('/dev/issue')
    .send({
      userId,
      role,
      app_code_challenge: createHash('sha256').update(codeVerifier).digest('base64url'),
    });
  const session = await request(app.server).post('/auth/session').send({
    code: issue.body.code,
    codeVerifier,
    redirectUri: 'resonance://auth-callback',
  });
  return session;
}
