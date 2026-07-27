// Verifies server and artifact errors with controlled dependency failures.
import request from 'supertest';
import { describe, expect, it } from 'vitest';
import { HeadObjectCommand } from '@aws-sdk/client-s3';
import { app, installBasicSuite, login, prisma, s3Mock } from './support/testUtils.js';

// Keep these cases together because they share one Fastify test lifecycle.

async function startArtifactSession(token: string, entryId: string, artifactId: string) {
  await prisma.practiceEntry.create({
    data: {
      id: entryId,
      courseId: 'COURSE_TEST',
      studentId: 'student-1',
      practiceDate: new Date(),
      goalText: 'Artifact session test',
      tags: ['tag'],
      status: 'draft',
    },
  });
  const created = await request(app.server)
    .post('/api/v1/artifact-sessions')
    .set('Authorization', `Bearer ${token}`)
    .send({
      operationId: `${artifactId}-operation`,
      entryId,
      artifactId,
      type: 'audio',
      durationSeconds: 60,
      sizeBytes: 128,
      baseVersion: 1,
    });
  expect(created.status).toBe(200);
  return created.body.sessionId as string;
}

function completeArtifactSessionRequest(token: string, sessionId: string) {
  return request(app.server)
    .post(`/api/v1/artifact-sessions/${sessionId}/complete`)
    .set('Authorization', `Bearer ${token}`)
    .send();
}

describe('server and artifact errors', () => {
  installBasicSuite({ resetS3: true });

  // ═══════════════════════════════════════════════════════════════════
  // server.ts error handler branches
  // ═══════════════════════════════════════════════════════════════════

  describe('server error handler', () => {
    it('returns 404 with NOT_FOUND for unknown routes', async () => {
      const res = await request(app.server).get('/nonexistent-route');
      expect(res.status).toBe(404);
      expect(res.body.error.code).toBe('NOT_FOUND');
      expect(res.body.error.message).toBe('Route not found');
    });

    it('returns 415 for unsupported content type on POST (preHandler)', async () => {
      const token = await login('student');
      const res = await request(app.server)
        .post('/courses/COURSE_TEST/entries')
        .set('Authorization', `Bearer ${token}`)
        .set('Content-Type', 'text/plain')
        .send('this is plain text');
      expect(res.status).toBe(415);
      expect(res.body.error.code).toBe('VALIDATION_ERROR');
      expect(res.body.error.message).toBe('Content-Type must be application/json');
    });

    it('returns 400 for invalid JSON body (FST_ERR_CTP_INVALID_JSON_BODY)', async () => {
      const token = await login('student');
      const res = await request(app.server)
        .post('/courses/COURSE_TEST/entries')
        .set('Authorization', `Bearer ${token}`)
        .set('Content-Type', 'application/json')
        .send('{ invalid json }');
      expect(res.status).toBe(400);
      expect(res.body.error.code).toBe('VALIDATION_ERROR');
      expect(res.body.error.message).toBe('Invalid JSON in request body');
    });

    it('returns 413 for body too large (FST_ERR_CTP_BODY_TOO_LARGE)', async () => {
      const token = await login('student');
      const largeBody = JSON.stringify({ payload: 'x'.repeat(1_100_000) });
      const res = await app.inject({
        method: 'POST',
        url: '/courses/COURSE_TEST/entries',
        headers: {
          authorization: `Bearer ${token}`,
          'content-type': 'application/json',
        },
        payload: largeBody,
      });
      const body = res.json();
      expect(res.statusCode).toBe(413);
      expect(body.error.code).toBe('VALIDATION_ERROR');
      expect(body.error.message).toBe('Request body is too large');
    });

    it('returns 401 MISSING_AUTH for unauthenticated protected routes', async () => {
      const res = await request(app.server).get('/courses');
      expect(res.status).toBe(401);
      expect(res.body.error.code).toBe('MISSING_AUTH');
    });

    it('returns 401 INVALID_TOKEN for invalid bearer token', async () => {
      const res = await request(app.server)
        .get('/courses')
        .set('Authorization', 'Bearer invalid-jwt-token');
      expect(res.status).toBe(401);
      expect(res.body.error.code).toBe('INVALID_TOKEN');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // artifact-session completion branches
  // ═══════════════════════════════════════════════════════════════════

  describe('artifact session completion edge cases', () => {
    it('returns 409 UPLOAD_INVALID when S3 HeadObject fails', async () => {
      const token = await login('student');

      const sessionId = await startArtifactSession(token, 'entry-s3-fail', 'artifact-s3-fail');

      s3Mock.on(HeadObjectCommand).rejects(
        Object.assign(new Error('Not Found'), {
          name: 'NotFound',
          $metadata: { httpStatusCode: 404 },
        })
      );

      const res = await completeArtifactSessionRequest(token, sessionId);

      expect(res.status).toBe(409);
      expect(res.body.error.code).toBe('UPLOAD_INVALID');
      expect(res.body.error.message).toBe('Uploaded object was not found');
    });

    it('returns 503 STORAGE_UNAVAILABLE for non-404 S3 failures', async () => {
      const token = await login('student');
      const sessionId = await startArtifactSession(token, 'entry-s3-denied', 'artifact-s3-denied');
      s3Mock.on(HeadObjectCommand).rejects(
        Object.assign(new Error('Access Denied'), {
          name: 'AccessDenied',
          $metadata: { httpStatusCode: 403 },
        })
      );

      const res = await completeArtifactSessionRequest(token, sessionId);

      expect(res.status).toBe(503);
      expect(res.body.error.code).toBe('STORAGE_UNAVAILABLE');
      const session = await prisma.artifactUploadSession.findUniqueOrThrow({
        where: { id: sessionId },
      });
      expect(session.completedAt).toBeNull();
    });

    it('returns 503 STORAGE_UNAVAILABLE for non-404 S3 failures', async () => {
      const token = await login('student');
      await prisma.practiceEntry.create({
        data: {
          id: 'entry-s3-denied',
          courseId: 'COURSE_TEST',
          studentId: 'student-1',
          practiceDate: new Date(),
          goalText: 'Test',
          tags: ['tag'],
          status: 'draft',
        },
      });
      await prisma.artifact.create({
        data: {
          id: 'artifact-s3-denied',
          entryId: 'entry-s3-denied',
          type: 'audio',
          durationSeconds: 60,
          uploadState: 'uploading',
          storageKey: 'artifacts/entry-s3-denied/artifact-s3-denied',
          expectedSizeBytes: 128,
          uploadExpiresAt: new Date(Date.now() + 60_000),
        },
      });
      s3Mock.on(HeadObjectCommand).rejects(
        Object.assign(new Error('Access Denied'), {
          name: 'AccessDenied',
          $metadata: { httpStatusCode: 403 },
        })
      );

      const res = await request(app.server)
        .post('/artifacts/artifact-s3-denied/confirm')
        .set('Authorization', `Bearer ${token}`)
        .send();

      expect(res.status).toBe(503);
      expect(res.body.error.code).toBe('STORAGE_UNAVAILABLE');
      const artifact = await prisma.artifact.findUniqueOrThrow({
        where: { id: 'artifact-s3-denied' },
      });
      expect(artifact.confirmationToken).toBeNull();
    });

    it('returns 409 UPLOAD_INVALID when uploaded file is empty (ContentLength 0)', async () => {
      const token = await login('student');

      const sessionId = await startArtifactSession(
        token,
        'entry-empty-file',
        'artifact-empty-file'
      );

      s3Mock.on(HeadObjectCommand).resolves({ ContentLength: 0 });

      const res = await request(app.server)
        .post(`/api/v1/artifact-sessions/${sessionId}/complete`)
        .set('Authorization', `Bearer ${token}`)
        .send();

      expect(res.status).toBe(409);
      expect(res.body.error.code).toBe('UPLOAD_INVALID');
      expect(res.body.error.message).toBe('Uploaded object size does not match the artifact');
    });

    it('returns 404 when completing a non-existent artifact session', async () => {
      const token = await login('student');
      const res = await request(app.server)
        .post('/api/v1/artifact-sessions/non-existent-session/complete')
        .set('Authorization', `Bearer ${token}`)
        .send();
      expect(res.status).toBe(404);
      expect(res.body.error.code).toBe('ARTIFACT_NOT_FOUND');
    });
  });
});
