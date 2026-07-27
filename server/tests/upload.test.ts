// Verifies legacy upload mutations stay retired in favor of versioned artifact sessions.
import request from 'supertest';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import {
  app,
  getAccessToken,
  resetDb,
  seedBasic,
  setupApp,
  teardownApp,
} from './support/testUtils.js';

describe('legacy artifact mutation routes', () => {
  let token: string;

  beforeAll(setupApp);
  beforeEach(async () => {
    await resetDb();
    await seedBasic();
    token = await getAccessToken('student', { userId: 'student-1' });
  });
  afterAll(teardownApp);

  it.each([
    [
      '/entries/entry-1/artifacts',
      { id: 'artifact-1', type: 'audio', durationSeconds: 1, sizeBytes: 1 },
    ],
    ['/artifacts/artifact-1/presign', {}],
    ['/artifacts/artifact-1/confirm', {}],
  ])('retires POST %s in favor of v1 artifact sessions', async (url, body) => {
    const response = await request(app.server)
      .post(url)
      .set('authorization', `Bearer ${token}`)
      .send(body);

    expect(response.status).toBe(410);
    expect(response.body.error).toMatchObject({
      code: 'UPLOAD_INVALID',
      message: expect.stringContaining('/api/v1/artifact-sessions'),
    });
  });
});
