// Exercises the v1 FIFO command contract, optimistic versions, replay, and result envelopes.
import request from 'supertest';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import {
  app,
  getAccessToken,
  prisma,
  resetDb,
  seedBasic,
  setupApp,
  teardownApp,
} from './support/testUtils.js';

describe('v1 sync command receipts and versions', () => {
  let studentToken: string;

  beforeAll(async () => {
    await setupApp();
  });
  beforeEach(async () => {
    await resetDb();
    await seedBasic();
    studentToken = await getAccessToken('student', { userId: 'student-1' });
  });
  afterAll(teardownApp);

  const create = (operationId = 'v1-create-1') => ({
    operationId,
    entityId: 'v1-entry-1',
    kind: 'createEntry',
    payload: {
      courseId: 'COURSE_TEST',
      kind: 'practice',
      practiceDate: '2026-07-16',
      goalText: 'Keep a steady pulse',
      tags: [],
    },
  });

  it('returns a duplicate receipt without applying the create twice', async () => {
    const first = await request(app.server)
      .post('/api/v1/sync/commands')
      .set('authorization', `Bearer ${studentToken}`)
      .send({ commands: [create()] });
    const retry = await request(app.server)
      .post('/api/v1/sync/commands')
      .set('authorization', `Bearer ${studentToken}`)
      .send({ commands: [create()] });
    expect(first.status).toBe(200);
    expect(first.body.results[0]).toMatchObject({ status: 'applied', currentVersion: 1 });
    expect(retry.status).toBe(200);
    expect(retry.body.results[0]).toMatchObject({ status: 'duplicate', currentVersion: 1 });
  });

  it('does not replay an entry resource after membership is revoked', async () => {
    await request(app.server)
      .post('/api/v1/sync/commands')
      .set('authorization', `Bearer ${studentToken}`)
      .send({ commands: [create('v1-revoked-replay')] });
    await prisma.membership.delete({
      where: { userId_courseId: { userId: 'student-1', courseId: 'COURSE_TEST' } },
    });

    const replay = await request(app.server)
      .post('/api/v1/sync/commands')
      .set('authorization', `Bearer ${studentToken}`)
      .send({ commands: [create('v1-revoked-replay')] });

    expect(replay.status).toBe(200);
    expect(replay.body.results[0]).toMatchObject({ status: 'rejected', code: 'STUDENT_ONLY' });
    expect(replay.body.results[0].resource).toBeUndefined();
  });

  it('rejects reuse of an operation ID with changed content', async () => {
    await request(app.server)
      .post('/api/v1/sync/commands')
      .set('authorization', `Bearer ${studentToken}`)
      .send({ commands: [create()] });
    const reused = create();
    reused.payload.goalText = 'Different intent';
    const response = await request(app.server)
      .post('/api/v1/sync/commands')
      .set('authorization', `Bearer ${studentToken}`)
      .send({ commands: [reused] });
    expect(response.status).toBe(200);
    expect(response.body.results[0]).toMatchObject({
      status: 'rejected',
      code: 'OPERATION_REUSED',
    });
  });

  it('returns the current resource for an optimistic-version conflict', async () => {
    await request(app.server)
      .post('/api/v1/sync/commands')
      .set('authorization', `Bearer ${studentToken}`)
      .send({ commands: [create()] });
    const response = await request(app.server)
      .post('/api/v1/sync/commands')
      .set('authorization', `Bearer ${studentToken}`)
      .send({
        commands: [
          {
            operationId: 'v1-update-stale',
            entityId: 'v1-entry-1',
            kind: 'updateEntry',
            baseVersion: 9,
            payload: { goalText: 'Stale' },
          },
        ],
      });
    expect(response.body.results[0]).toMatchObject({
      status: 'conflict',
      code: 'VERSION_CONFLICT',
      currentVersion: 1,
    });
  });
});
