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
  s3Mock,
} from './testUtils.js';

function login(role: 'student' | 'teacher') {
  const userId = role === 'student' ? 'student-1' : 'teacher-1';
  return getAccessToken(role, { userId });
}
describe('edge cases', () => {
  beforeAll(async () => {
    await setupApp();
  });

  afterAll(async () => {
    await teardownApp();
  });

  beforeEach(async () => {
    s3Mock.reset();
    await resetDb();
    await seedBasic();
  });
  // ═══════════════════════════════════════════════════════════════════
  // Category 2: Maximum / Boundary Inputs
  // ═══════════════════════════════════════════════════════════════════

  describe('Category 2: Maximum/boundary inputs', () => {
    describe('POST /courses/:courseId/entries', () => {
      it('should accept ID at max length (128 chars)', async () => {
        const token = await login('student');
        const maxId = 'a'.repeat(128);
        const res = await request(app.server)
          .post('/courses/COURSE_TEST/entries')
          .set('Authorization', `Bearer ${token}`)
          .send({
            id: maxId,
            practiceDate: new Date().toISOString(),
            goalText: 'Max ID test',
            tags: [],
          });
        expect(res.status).toBe(201);
        expect(res.body.id).toBe(maxId);
      });

      it('should reject ID exceeding max length (129 chars)', async () => {
        const token = await login('student');
        const tooLongId = 'a'.repeat(129);
        const res = await request(app.server)
          .post('/courses/COURSE_TEST/entries')
          .set('Authorization', `Bearer ${token}`)
          .send({
            id: tooLongId,
            practiceDate: new Date().toISOString(),
            goalText: 'Too long ID',
            tags: [],
          });
        expect(res.status).toBe(400);
        expect(res.body.error?.code).toBe('VALIDATION_ERROR');
      });

      it('should accept tags at max count (30)', async () => {
        const token = await login('student');
        const tags = Array.from({ length: 30 }, (_, i) => `tag-${i}`);
        const res = await request(app.server)
          .post('/courses/COURSE_TEST/entries')
          .set('Authorization', `Bearer ${token}`)
          .send({
            id: 'entry-30-tags',
            practiceDate: new Date().toISOString(),
            goalText: 'Max tags test',
            tags,
          });
        expect(res.status).toBe(201);
        expect(res.body.tags).toHaveLength(30);
      });

      it('should accept goalText at max length (10000 chars)', async () => {
        const token = await login('student');
        const goalText = 'g'.repeat(10000);
        const res = await request(app.server)
          .post('/courses/COURSE_TEST/entries')
          .set('Authorization', `Bearer ${token}`)
          .send({
            id: 'entry-max-goal',
            practiceDate: new Date().toISOString(),
            goalText,
            tags: [],
          });
        expect(res.status).toBe(201);
        expect(res.body.goalText).toHaveLength(10000);
      });

      it('should reject goalText exceeding max length (10001 chars)', async () => {
        const token = await login('student');
        const goalText = 'g'.repeat(10001);
        const res = await request(app.server)
          .post('/courses/COURSE_TEST/entries')
          .set('Authorization', `Bearer ${token}`)
          .send({
            id: 'entry-too-long-goal',
            practiceDate: new Date().toISOString(),
            goalText,
            tags: [],
          });
        expect(res.status).toBe(400);
        expect(res.body.error?.code).toBe('VALIDATION_ERROR');
      });

      it('should accept durationSeconds at max (28800)', async () => {
        const token = await login('student');
        const res = await request(app.server)
          .post('/courses/COURSE_TEST/entries')
          .set('Authorization', `Bearer ${token}`)
          .send({
            id: 'entry-dur-28800',
            practiceDate: new Date().toISOString(),
            goalText: 'Max duration',
            tags: [],
            durationSeconds: 28800,
          });
        expect(res.status).toBe(201);
        expect(res.body.durationSeconds).toBe(28800);
      });

      it('should reject durationSeconds just above max (28801)', async () => {
        const token = await login('student');
        const res = await request(app.server)
          .post('/courses/COURSE_TEST/entries')
          .set('Authorization', `Bearer ${token}`)
          .send({
            id: 'entry-dur-28801',
            practiceDate: new Date().toISOString(),
            goalText: 'Over max duration',
            tags: [],
            durationSeconds: 28801,
          });
        expect(res.status).toBe(400);
        expect(res.body.error?.code).toBe('VALIDATION_ERROR');
      });
    });

    describe('POST /feedback', () => {
      let entryId: string;

      beforeEach(async () => {
        entryId = 'entry-fb-boundary';
        await prisma.practiceEntry.create({
          data: {
            id: entryId,
            courseId: 'COURSE_TEST',
            studentId: 'student-1',
            practiceDate: new Date(),
            goalText: 'Boundary test',
            tags: [],
            status: 'submitted',
          },
        });
      });

      it('should accept marker count at exactly 50', async () => {
        const token = await login('teacher');
        const markers = Array.from({ length: 50 }, (_, i) => ({
          timeSeconds: i * 10,
          text: `Marker ${i}`,
        }));
        const res = await request(app.server)
          .post('/feedback')
          .set('Authorization', `Bearer ${token}`)
          .send({
            targetType: 'entry',
            targetId: entryId,
            status: 'ok',
            commentsText: 'With 50 markers',
            markers,
          });
        expect(res.status).toBe(201);
        expect(res.body.markers).toHaveLength(50);
      });

      it('should reject marker count at 51', async () => {
        const token = await login('teacher');
        const markers = Array.from({ length: 51 }, (_, i) => ({
          timeSeconds: i * 10,
          text: `Marker ${i}`,
        }));
        const res = await request(app.server)
          .post('/feedback')
          .set('Authorization', `Bearer ${token}`)
          .send({
            targetType: 'entry',
            targetId: entryId,
            status: 'ok',
            commentsText: 'With 51 markers',
            markers,
          });
        expect(res.status).toBe(400);
        expect(res.body.error?.code).toBe('VALIDATION_ERROR');
      });

      it('should accept marker timeSeconds at boundary 0', async () => {
        const token = await login('teacher');
        const res = await request(app.server)
          .post('/feedback')
          .set('Authorization', `Bearer ${token}`)
          .send({
            targetType: 'entry',
            targetId: entryId,
            status: 'ok',
            commentsText: 'Boundary marker',
            markers: [{ timeSeconds: 0, text: 'At start' }],
          });
        expect(res.status).toBe(201);
        expect(res.body.markers[0].timeSeconds).toBe(0);
      });

      it('should accept marker timeSeconds at boundary 28800', async () => {
        const token = await login('teacher');
        const res = await request(app.server)
          .post('/feedback')
          .set('Authorization', `Bearer ${token}`)
          .send({
            targetType: 'entry',
            targetId: entryId,
            status: 'ok',
            commentsText: 'Max time marker',
            markers: [{ timeSeconds: 28800, text: 'At max' }],
          });
        expect(res.status).toBe(201);
        expect(res.body.markers[0].timeSeconds).toBe(28800);
      });

      it('should reject marker timeSeconds at 28801', async () => {
        const token = await login('teacher');
        const res = await request(app.server)
          .post('/feedback')
          .set('Authorization', `Bearer ${token}`)
          .send({
            targetType: 'entry',
            targetId: entryId,
            status: 'ok',
            commentsText: 'Over max time marker',
            markers: [{ timeSeconds: 28801, text: 'Over max' }],
          });
        expect(res.status).toBe(400);
        expect(res.body.error?.code).toBe('VALIDATION_ERROR');
      });

      it('should reject negative marker timeSeconds', async () => {
        const token = await login('teacher');
        const res = await request(app.server)
          .post('/feedback')
          .set('Authorization', `Bearer ${token}`)
          .send({
            targetType: 'entry',
            targetId: entryId,
            status: 'ok',
            commentsText: 'Negative time',
            markers: [{ timeSeconds: -1, text: 'Negative' }],
          });
        expect(res.status).toBe(400);
        expect(res.body.error?.code).toBe('VALIDATION_ERROR');
      });

      it('should accept marker text at max length (1000 chars)', async () => {
        const token = await login('teacher');
        const res = await request(app.server)
          .post('/feedback')
          .set('Authorization', `Bearer ${token}`)
          .send({
            targetType: 'entry',
            targetId: entryId,
            status: 'ok',
            commentsText: 'Max marker text',
            markers: [{ timeSeconds: 10, text: 'm'.repeat(1000) }],
          });
        expect(res.status).toBe(201);
        expect(res.body.markers[0].text).toHaveLength(1000);
      });

      it('should accept commentsText at max length (10000 chars)', async () => {
        const token = await login('teacher');
        const res = await request(app.server)
          .post('/feedback')
          .set('Authorization', `Bearer ${token}`)
          .send({
            targetType: 'entry',
            targetId: entryId,
            status: 'ok',
            commentsText: 'c'.repeat(10000),
            markers: [],
          });
        expect(res.status).toBe(201);
        expect(res.body.commentsText).toHaveLength(10000);
      });
    });

    describe('POST /entries/:entryId/artifacts', () => {
      it('should accept artifact ID at max length (128 chars)', async () => {
        const token = await login('student');
        await prisma.practiceEntry.create({
          data: {
            id: 'entry-art-maxid',
            courseId: 'COURSE_TEST',
            studentId: 'student-1',
            practiceDate: new Date(),
            goalText: 'Artifact ID test',
            tags: [],
            status: 'draft',
          },
        });
        const maxId = 'b'.repeat(128);
        const res = await request(app.server)
          .post('/entries/entry-art-maxid/artifacts')
          .set('Authorization', `Bearer ${token}`)
          .send({ id: maxId, type: 'audio', durationSeconds: 60 });
        expect(res.status).toBe(201);
        expect(res.body.id).toBe(maxId);
      });

      it('should accept zero durationSeconds for artifact', async () => {
        const token = await login('student');
        await prisma.practiceEntry.create({
          data: {
            id: 'entry-art-zero-dur',
            courseId: 'COURSE_TEST',
            studentId: 'student-1',
            practiceDate: new Date(),
            goalText: 'Zero dur artifact',
            tags: [],
            status: 'draft',
          },
        });
        const res = await request(app.server)
          .post('/entries/entry-art-zero-dur/artifacts')
          .set('Authorization', `Bearer ${token}`)
          .send({ id: 'art-zero-dur', type: 'audio', durationSeconds: 0 });
        expect(res.status).toBe(201);
        expect(res.body.durationSeconds).toBe(0);
      });
    });
  });
});
