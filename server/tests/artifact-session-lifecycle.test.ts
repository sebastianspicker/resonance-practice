// The supported upload path allocates, finalizes to an immutable key, and never reissues a PUT credential.
import { CopyObjectCommand, HeadObjectCommand } from '@aws-sdk/client-s3';
import request from 'supertest';
import { describe, expect, it } from 'vitest';
import { assertArtifactSessionCapacity } from '../src/services/entryTransaction.js';
import { app, installBasicSuite, login, prisma, s3Mock } from './support/testUtils.js';

describe('artifact-session lifecycle', () => {
  installBasicSuite({ resetS3: true });

  it('allocates once, finalizes to a claim-specific key, and never reissues a completed credential', async () => {
    await prisma.practiceEntry.create({
      data: {
        id: 'upload-entry',
        courseId: 'COURSE_TEST',
        studentId: 'student-1',
        practiceDate: new Date(),
        goalText: 'Record',
        tags: [],
      },
    });
    const token = await login('student');
    const payload = {
      operationId: 'upload-operation',
      entryId: 'upload-entry',
      artifactId: 'upload-artifact',
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

    s3Mock.on(HeadObjectCommand).resolves({ ContentLength: 128, ETag: '"etag"' });
    s3Mock.on(CopyObjectCommand).resolves({});
    const completed = await request(app.server)
      .post(`/api/v1/artifact-sessions/${created.body.sessionId}/complete`)
      .set('authorization', `Bearer ${token}`)
      .send();
    const replay = await request(app.server)
      .post('/api/v1/artifact-sessions')
      .set('authorization', `Bearer ${token}`)
      .send(payload);

    expect(completed.body.artifact.storageKey).toMatch(
      /^artifacts\/final\/upload-entry\/upload-artifact-/
    );
    expect(completed.body.artifact.storageKey).not.toBe(created.body.artifact.storageKey);
    expect(s3Mock.commandCalls(CopyObjectCommand)).toHaveLength(1);
    expect(replay.body).toMatchObject({ completed: true, uploadUrl: null, requiredHeaders: null });
  });

  it('maps quota exhaustion to a rate-limited API error before an artifact is admitted', async () => {
    const tx = {
      artifactUploadSession: { count: async () => 24 },
      artifact: {
        aggregate: async () => ({ _count: { _all: 0 }, _sum: { expectedSizeBytes: 0 } }),
      },
    } as never;
    await expect(
      assertArtifactSessionCapacity(tx, 'student-1', 'entry-1', 1, new Date())
    ).rejects.toMatchObject({
      statusCode: 429,
      code: 'RATE_LIMITED',
    });
  });
});
