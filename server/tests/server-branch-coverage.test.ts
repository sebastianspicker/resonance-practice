import request from 'supertest';
import { beforeAll, afterAll, beforeEach, describe, expect, it } from 'vitest';
import { HeadObjectCommand } from '@aws-sdk/client-s3';
import {
  app,
  setupApp,
  teardownApp,
  resetDb,
  seedBasic,
  getAccessToken,
  prisma,
  s3Mock,
} from './testUtils.js';

/**
 * Combined integration tests covering specific uncovered branches in:
 * - server.ts error handler (CTP errors, 5xx/4xx, body too large)
 * - artifacts.ts confirm (S3 HeadObject failure, missing storage key)
 *
 * These are in one file to avoid the shared-singleton teardown issue
 * where multiple files calling setupApp/teardownApp on the same Fastify
 * instance cause conflicts.
 */

function login(role: 'student' | 'teacher') {
  const userId = role === 'student' ? 'student-1' : 'teacher-1';
  return getAccessToken(role, { userId });
}

describe('server & artifact branch coverage', () => {
  beforeAll(async () => {
    await setupApp();
  });

  afterAll(async () => {
    await teardownApp();
  });

  beforeEach(async () => {
    await resetDb();
    await seedBasic();
    s3Mock.reset();
  });

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
      const res = await request(app.server)
        .post('/courses/COURSE_TEST/entries')
        .set('Authorization', `Bearer ${token}`)
        .set('Content-Type', 'application/json')
        .send(largeBody);
      expect(res.status).toBe(413);
      expect(res.body.error.code).toBe('VALIDATION_ERROR');
      expect(res.body.error.message).toBe('Request body is too large');
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
  // artifacts.ts confirm branches
  // ═══════════════════════════════════════════════════════════════════

  describe('artifact confirm edge cases', () => {
    it('returns 400 MISSING_STORAGE_KEY when artifact has no storageKey', async () => {
      const token = await login('student');

      await prisma.practiceEntry.create({
        data: {
          id: 'entry-no-key',
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
          id: 'artifact-no-key',
          entryId: 'entry-no-key',
          type: 'audio',
          durationSeconds: 60,
          uploadState: 'uploading',
          storageKey: null,
        },
      });

      const res = await request(app.server)
        .post('/artifacts/artifact-no-key/confirm')
        .set('Authorization', `Bearer ${token}`)
        .send();

      expect(res.status).toBe(400);
      expect(res.body.error.code).toBe('MISSING_STORAGE_KEY');
      expect(res.body.error.message).toBe('Artifact missing storage key');
    });

    it('returns 409 UPLOAD_INVALID when S3 HeadObject fails', async () => {
      const token = await login('student');

      await prisma.practiceEntry.create({
        data: {
          id: 'entry-s3-fail',
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
          id: 'artifact-s3-fail',
          entryId: 'entry-s3-fail',
          type: 'audio',
          durationSeconds: 60,
          uploadState: 'uploading',
          storageKey: 'artifacts/entry-s3-fail/artifact-s3-fail',
        },
      });

      s3Mock.on(HeadObjectCommand).rejects(
        Object.assign(new Error('Not Found'), {
          name: 'NotFound',
          $metadata: { httpStatusCode: 404 },
        })
      );

      const res = await request(app.server)
        .post('/artifacts/artifact-s3-fail/confirm')
        .set('Authorization', `Bearer ${token}`)
        .send();

      expect(res.status).toBe(409);
      expect(res.body.error.code).toBe('UPLOAD_INVALID');
      expect(res.body.error.message).toBe('Upload not found in storage');
    });

    it('returns 409 UPLOAD_INVALID when uploaded file is empty (ContentLength 0)', async () => {
      const token = await login('student');

      await prisma.practiceEntry.create({
        data: {
          id: 'entry-empty-file',
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
          id: 'artifact-empty-file',
          entryId: 'entry-empty-file',
          type: 'audio',
          durationSeconds: 60,
          uploadState: 'uploading',
          storageKey: 'artifacts/entry-empty-file/artifact-empty-file',
        },
      });

      s3Mock.on(HeadObjectCommand).resolves({ ContentLength: 0 });

      const res = await request(app.server)
        .post('/artifacts/artifact-empty-file/confirm')
        .set('Authorization', `Bearer ${token}`)
        .send();

      expect(res.status).toBe(409);
      expect(res.body.error.code).toBe('UPLOAD_INVALID');
      expect(res.body.error.message).toBe('Uploaded file is empty');
    });

    it('returns 404 when confirming a non-existent artifact', async () => {
      const token = await login('student');
      const res = await request(app.server)
        .post('/artifacts/non-existent-artifact/confirm')
        .set('Authorization', `Bearer ${token}`)
        .send();
      expect(res.status).toBe(404);
      expect(res.body.error.code).toBe('ARTIFACT_NOT_FOUND');
    });
  });
});
