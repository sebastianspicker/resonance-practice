import request from 'supertest';
import { beforeAll, afterAll, beforeEach, describe, expect, it } from 'vitest';
import {
  app,
  setupApp,
  teardownApp,
  resetDb,
  seedBasic,
  getAccessToken,
  prisma,
} from './testUtils.js';

function login(role: 'student' | 'teacher') {
  const userId = role === 'student' ? 'student-1' : 'teacher-1';
  return getAccessToken(role, { userId });
}

describe('input validation', () => {
  beforeAll(async () => {
    await setupApp();
  });

  afterAll(async () => {
    await teardownApp();
  });

  beforeEach(async () => {
    await resetDb();
    await seedBasic();
  });

  // ── POST /courses/:courseId/entries ──

  describe('POST /courses/:courseId/entries', () => {
    it('rejects durationSeconds exceeding upper bound', async () => {
      const token = await login('student');
      const res = await request(app.server)
        .post('/courses/COURSE_TEST/entries')
        .set('Authorization', `Bearer ${token}`)
        .send({
          id: 'entry-dur-too-high',
          practiceDate: new Date().toISOString(),
          goalText: 'Test',
          tags: [],
          durationSeconds: 99999,
        });
      expect(res.status).toBe(400);
      expect(res.body.error?.code).toBe('VALIDATION_ERROR');
    });

    it('accepts durationSeconds at upper bound (28800)', async () => {
      const token = await login('student');
      const res = await request(app.server)
        .post('/courses/COURSE_TEST/entries')
        .set('Authorization', `Bearer ${token}`)
        .send({
          id: 'entry-dur-max',
          practiceDate: new Date().toISOString(),
          goalText: 'Test',
          tags: [],
          durationSeconds: 28800,
        });
      expect(res.status).toBe(201);
      expect(res.body.durationSeconds).toBe(28800);
    });

    it('rejects too many tags', async () => {
      const token = await login('student');
      const tags = Array.from({ length: 31 }, (_, i) => `tag-${i}`);
      const res = await request(app.server)
        .post('/courses/COURSE_TEST/entries')
        .set('Authorization', `Bearer ${token}`)
        .send({
          id: 'entry-too-many-tags',
          practiceDate: new Date().toISOString(),
          goalText: 'Test',
          tags,
        });
      expect(res.status).toBe(400);
      expect(res.body.error?.code).toBe('VALIDATION_ERROR');
    });

    it('rejects tag exceeding max length', async () => {
      const token = await login('student');
      const res = await request(app.server)
        .post('/courses/COURSE_TEST/entries')
        .set('Authorization', `Bearer ${token}`)
        .send({
          id: 'entry-long-tag',
          practiceDate: new Date().toISOString(),
          goalText: 'Test',
          tags: ['a'.repeat(101)],
        });
      expect(res.status).toBe(400);
      expect(res.body.error?.code).toBe('VALIDATION_ERROR');
    });

    it('accepts tag at max length (100)', async () => {
      const token = await login('student');
      const res = await request(app.server)
        .post('/courses/COURSE_TEST/entries')
        .set('Authorization', `Bearer ${token}`)
        .send({
          id: 'entry-max-tag',
          practiceDate: new Date().toISOString(),
          goalText: 'Test',
          tags: ['a'.repeat(100)],
        });
      expect(res.status).toBe(201);
    });

    it('rejects negative durationSeconds', async () => {
      const token = await login('student');
      const res = await request(app.server)
        .post('/courses/COURSE_TEST/entries')
        .set('Authorization', `Bearer ${token}`)
        .send({
          id: 'entry-neg-dur',
          practiceDate: new Date().toISOString(),
          goalText: 'Test',
          tags: [],
          durationSeconds: -1,
        });
      expect(res.status).toBe(400);
    });

    it('rejects decimal durationSeconds', async () => {
      const token = await login('student');
      const res = await request(app.server)
        .post('/courses/COURSE_TEST/entries')
        .set('Authorization', `Bearer ${token}`)
        .send({
          id: 'entry-decimal-dur',
          practiceDate: new Date().toISOString(),
          goalText: 'Test',
          tags: [],
          durationSeconds: 1.5,
        });
      expect(res.status).toBe(400);
      expect(res.body.error?.code).toBe('VALIDATION_ERROR');
    });

    it('rejects impossible calendar dates', async () => {
      const token = await login('student');
      const res = await request(app.server)
        .post('/courses/COURSE_TEST/entries')
        .set('Authorization', `Bearer ${token}`)
        .send({
          id: 'entry-impossible-date',
          practiceDate: '2025-02-30',
          goalText: 'Test',
          tags: [],
        });
      expect(res.status).toBe(400);
      expect(res.body.error?.code).toBe('VALIDATION_ERROR');
    });
  });

  // ── PATCH /entries/:entryId ──

  describe('PATCH /entries/:entryId', () => {
    let entryId: string;

    beforeEach(async () => {
      entryId = 'entry-patch-test';
      await prisma.practiceEntry.create({
        data: {
          id: entryId,
          courseId: 'COURSE_TEST',
          studentId: 'student-1',
          practiceDate: new Date(),
          goalText: 'Original',
          tags: ['original'],
          status: 'draft',
        },
      });
    });

    it('rejects durationSeconds exceeding upper bound', async () => {
      const token = await login('student');
      const res = await request(app.server)
        .patch(`/entries/${entryId}`)
        .set('Authorization', `Bearer ${token}`)
        .send({ durationSeconds: 30000 });
      expect(res.status).toBe(400);
      expect(res.body.error?.code).toBe('VALIDATION_ERROR');
    });

    it('allows null to clear durationSeconds', async () => {
      const token = await login('student');
      // First set it
      await request(app.server)
        .patch(`/entries/${entryId}`)
        .set('Authorization', `Bearer ${token}`)
        .send({ durationSeconds: 100 });
      // Then clear it
      const res = await request(app.server)
        .patch(`/entries/${entryId}`)
        .set('Authorization', `Bearer ${token}`)
        .send({ durationSeconds: null });
      expect(res.status).toBe(200);
      expect(res.body.durationSeconds).toBeNull();
    });

    it('allows null to clear notes', async () => {
      const token = await login('student');
      await request(app.server)
        .patch(`/entries/${entryId}`)
        .set('Authorization', `Bearer ${token}`)
        .send({ notes: 'Some notes' });
      const res = await request(app.server)
        .patch(`/entries/${entryId}`)
        .set('Authorization', `Bearer ${token}`)
        .send({ notes: null });
      expect(res.status).toBe(200);
      expect(res.body.notes).toBeNull();
    });

    it('rejects tag exceeding max length in PATCH', async () => {
      const token = await login('student');
      const res = await request(app.server)
        .patch(`/entries/${entryId}`)
        .set('Authorization', `Bearer ${token}`)
        .send({ tags: ['a'.repeat(101)] });
      expect(res.status).toBe(400);
    });

    it('rejects too many tags in PATCH', async () => {
      const token = await login('student');
      const tags = Array.from({ length: 31 }, (_, i) => `tag-${i}`);
      const res = await request(app.server)
        .patch(`/entries/${entryId}`)
        .set('Authorization', `Bearer ${token}`)
        .send({ tags });
      expect(res.status).toBe(400);
    });

    it('locks submitted entries using field presence (not truthiness)', async () => {
      await prisma.practiceEntry.update({
        where: { id: entryId },
        data: { status: 'submitted' },
      });
      const token = await login('student');

      // Even sending falsy values like empty string should trigger the lock
      const res = await request(app.server)
        .patch(`/entries/${entryId}`)
        .set('Authorization', `Bearer ${token}`)
        .send({ goalText: '' });
      expect(res.status).toBe(409);
      expect(res.body.error?.code).toBe('ENTRY_LOCKED');
    });

    it('rejects decimal durationSeconds in PATCH', async () => {
      const token = await login('student');
      const res = await request(app.server)
        .patch(`/entries/${entryId}`)
        .set('Authorization', `Bearer ${token}`)
        .send({ durationSeconds: 12.5 });
      expect(res.status).toBe(400);
      expect(res.body.error?.code).toBe('VALIDATION_ERROR');
    });
  });

  // ── POST /entries/:entryId/artifacts ──

  describe('POST /entries/:entryId/artifacts', () => {
    let entryId: string;

    beforeEach(async () => {
      entryId = 'entry-artifact-val';
      await prisma.practiceEntry.create({
        data: {
          id: entryId,
          courseId: 'COURSE_TEST',
          studentId: 'student-1',
          practiceDate: new Date(),
          goalText: 'Artifact test',
          tags: ['tag'],
          status: 'draft',
        },
      });
    });

    it('rejects durationSeconds exceeding upper bound', async () => {
      const token = await login('student');
      const res = await request(app.server)
        .post(`/entries/${entryId}/artifacts`)
        .set('Authorization', `Bearer ${token}`)
        .send({ id: 'artifact-dur-high', type: 'audio', durationSeconds: 50000 });
      expect(res.status).toBe(400);
      expect(res.body.error?.code).toBe('VALIDATION_ERROR');
    });

    it('accepts durationSeconds at upper bound', async () => {
      const token = await login('student');
      const res = await request(app.server)
        .post(`/entries/${entryId}/artifacts`)
        .set('Authorization', `Bearer ${token}`)
        .send({ id: 'artifact-dur-ok', type: 'audio', durationSeconds: 28800 });
      expect(res.status).toBe(201);
      expect(res.body.durationSeconds).toBe(28800);
    });

    it('rejects negative durationSeconds', async () => {
      const token = await login('student');
      const res = await request(app.server)
        .post(`/entries/${entryId}/artifacts`)
        .set('Authorization', `Bearer ${token}`)
        .send({ id: 'artifact-neg', type: 'audio', durationSeconds: -5 });
      expect(res.status).toBe(400);
    });

    it('rejects decimal durationSeconds', async () => {
      const token = await login('student');
      const res = await request(app.server)
        .post(`/entries/${entryId}/artifacts`)
        .set('Authorization', `Bearer ${token}`)
        .send({ id: 'artifact-decimal', type: 'audio', durationSeconds: 12.25 });
      expect(res.status).toBe(400);
      expect(res.body.error?.code).toBe('VALIDATION_ERROR');
    });
  });

  // ── POST /feedback ──

  describe('POST /feedback', () => {
    let entryId: string;

    beforeEach(async () => {
      entryId = 'entry-feedback-val';
      await prisma.practiceEntry.create({
        data: {
          id: entryId,
          courseId: 'COURSE_TEST',
          studentId: 'student-1',
          practiceDate: new Date(),
          goalText: 'Feedback target',
          tags: ['tag'],
          status: 'submitted',
        },
      });
    });

    it('rejects commentsText exceeding max length', async () => {
      const token = await login('teacher');
      const res = await request(app.server)
        .post('/feedback')
        .set('Authorization', `Bearer ${token}`)
        .send({
          targetType: 'entry',
          targetId: entryId,
          status: 'ok',
          commentsText: 'x'.repeat(10001),
          markers: [],
        });
      expect(res.status).toBe(400);
      expect(res.body.error?.code).toBe('VALIDATION_ERROR');
    });

    it('accepts commentsText at max length', async () => {
      const token = await login('teacher');
      const res = await request(app.server)
        .post('/feedback')
        .set('Authorization', `Bearer ${token}`)
        .send({
          targetType: 'entry',
          targetId: entryId,
          status: 'ok',
          commentsText: 'x'.repeat(10000),
          markers: [],
        });
      expect(res.status).toBe(201);
    });

    it('rejects marker with timeSeconds exceeding upper bound', async () => {
      const token = await login('teacher');
      const res = await request(app.server)
        .post('/feedback')
        .set('Authorization', `Bearer ${token}`)
        .send({
          targetType: 'entry',
          targetId: entryId,
          status: 'ok',
          commentsText: 'Review',
          markers: [{ timeSeconds: 99999, text: 'Too far' }],
        });
      expect(res.status).toBe(400);
      expect(res.body.error?.code).toBe('VALIDATION_ERROR');
    });

    it('rejects marker missing text', async () => {
      const token = await login('teacher');
      const res = await request(app.server)
        .post('/feedback')
        .set('Authorization', `Bearer ${token}`)
        .send({
          targetType: 'entry',
          targetId: entryId,
          status: 'ok',
          commentsText: 'Review',
          markers: [{ timeSeconds: 10 }],
        });
      expect(res.status).toBe(400);
    });

    it('rejects marker missing timeSeconds', async () => {
      const token = await login('teacher');
      const res = await request(app.server)
        .post('/feedback')
        .set('Authorization', `Bearer ${token}`)
        .send({
          targetType: 'entry',
          targetId: entryId,
          status: 'ok',
          commentsText: 'Review',
          markers: [{ text: 'No time' }],
        });
      expect(res.status).toBe(400);
    });

    it('rejects marker with text exceeding max length', async () => {
      const token = await login('teacher');
      const res = await request(app.server)
        .post('/feedback')
        .set('Authorization', `Bearer ${token}`)
        .send({
          targetType: 'entry',
          targetId: entryId,
          status: 'ok',
          commentsText: 'Review',
          markers: [{ timeSeconds: 5, text: 'z'.repeat(1001) }],
        });
      expect(res.status).toBe(400);
    });

    it('rejects marker with decimal timeSeconds', async () => {
      const token = await login('teacher');
      const res = await request(app.server)
        .post('/feedback')
        .set('Authorization', `Bearer ${token}`)
        .send({
          targetType: 'entry',
          targetId: entryId,
          status: 'ok',
          commentsText: 'Review',
          markers: [{ timeSeconds: 12.5, text: 'Half second' }],
        });
      expect(res.status).toBe(400);
      expect(res.body.error?.code).toBe('VALIDATION_ERROR');
    });
  });

  // ── POST /auth/session ──

  describe('POST /auth/session', () => {
    it('rejects non-string code', async () => {
      const res = await request(app.server).post('/auth/session').send({ code: 12345 });
      expect(res.status).toBe(400);
      expect(res.body.error?.code).toBe('VALIDATION_ERROR');
    });

    it('rejects missing code', async () => {
      const res = await request(app.server).post('/auth/session').send({});
      expect(res.status).toBe(400);
    });

    it('rejects overly long code', async () => {
      const res = await request(app.server)
        .post('/auth/session')
        .send({ code: 'a'.repeat(2049) });
      expect(res.status).toBe(400);
      expect(res.body.error?.code).toBe('VALIDATION_ERROR');
    });
  });

  // ── POST /auth/refresh ──

  describe('POST /auth/refresh', () => {
    it('rejects non-string refreshToken', async () => {
      const res = await request(app.server).post('/auth/refresh').send({ refreshToken: 12345 });
      expect(res.status).toBe(400);
      expect(res.body.error?.code).toBe('VALIDATION_ERROR');
    });

    it('rejects missing refreshToken', async () => {
      const res = await request(app.server).post('/auth/refresh').send({});
      expect(res.status).toBe(400);
    });

    it('rejects overly long refreshToken', async () => {
      const res = await request(app.server)
        .post('/auth/refresh')
        .send({ refreshToken: 'a'.repeat(2049) });
      expect(res.status).toBe(400);
      expect(res.body.error?.code).toBe('VALIDATION_ERROR');
    });
  });

  describe('POST /auth/logout', () => {
    it('rejects non-object bodies', async () => {
      const res = await request(app.server)
        .post('/auth/logout')
        .set('Content-Type', 'application/json')
        .send('"token"');
      expect(res.status).toBe(400);
      expect(res.body.error?.code).toBe('VALIDATION_ERROR');
    });

    it('rejects non-string refreshToken', async () => {
      const res = await request(app.server).post('/auth/logout').send({ refreshToken: 12345 });
      expect(res.status).toBe(400);
      expect(res.body.error?.code).toBe('VALIDATION_ERROR');
    });
  });
});
