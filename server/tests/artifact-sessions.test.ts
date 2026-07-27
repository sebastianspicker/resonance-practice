// Verifies the authenticated artifact-session API against the integration test database.
import request from 'supertest';
import { CopyObjectCommand, HeadObjectCommand } from '@aws-sdk/client-s3';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import {
  app,
  getAccessToken,
  prisma,
  resetDb,
  seedBasic,
  setupApp,
  teardownApp,
  s3Mock,
} from './support/testUtils.js';

describe('v1 artifact upload sessions', () => {
  let token: string;

  beforeAll(setupApp);
  beforeEach(async () => {
    await resetDb();
    await seedBasic();
    s3Mock.reset();
    token = await getAccessToken('student', { userId: 'student-1' });
  });
  afterAll(teardownApp);

  it('publishes a unique final key and never reissues a completed session credential', async () => {
    await prisma.practiceEntry.create({
      data: {
        id: 'entry-upload-session',
        courseId: 'COURSE_TEST',
        studentId: 'student-1',
        practiceDate: new Date(),
        goalText: 'Record a phrase',
        tags: [],
      },
    });
    const payload = {
      operationId: 'upload-operation-1',
      entryId: 'entry-upload-session',
      artifactId: 'artifact-upload-session',
      type: 'audio',
      durationSeconds: 30,
      sizeBytes: 128,
      baseVersion: 1,
    };
    const created = await request(app.server)
      .post('/api/v1/artifact-sessions')
      .set('authorization', `Bearer ${token}`)
      .send(payload);

    expect(created.status).toBe(200);
    expect(created.body.artifact.storageKey).toMatch(/^artifacts\/staging\//);
    s3Mock.on(HeadObjectCommand).resolves({ ContentLength: 128, ETag: '"etag-1"' });
    s3Mock.on(CopyObjectCommand).resolves({});

    const completed = await request(app.server)
      .post(`/api/v1/artifact-sessions/${created.body.sessionId}/complete`)
      .set('authorization', `Bearer ${token}`)
      .send();

    expect(completed.status).toBe(200);
    expect(completed.body.artifact.storageKey).toMatch(/^artifacts\/final\//);
    expect(s3Mock.commandCalls(CopyObjectCommand)).toHaveLength(1);

    const retry = await request(app.server)
      .post('/api/v1/artifact-sessions')
      .set('authorization', `Bearer ${token}`)
      .send(payload);
    expect(retry.status).toBe(200);
    expect(retry.body).toMatchObject({ completed: true, uploadUrl: null, requiredHeaders: null });

    const cleanup = await prisma.storageDeletionJob.findFirstOrThrow({
      where: { entryId: 'entry-upload-session' },
    });
    expect(cleanup.storageKey).toMatch(/^artifacts\/staging\//);
    expect(cleanup.nextAttemptAt.getTime()).toBeGreaterThan(Date.now());
  });
});
