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
  // Category 5: State Transitions
  // ═══════════════════════════════════════════════════════════════════

  describe('Category 5: State transitions', () => {
    describe('POST /entries/:entryId/submit', () => {
      it('should reject re-submitting an already submitted entry', async () => {
        const token = await login('student');
        await prisma.practiceEntry.create({
          data: {
            id: 'entry-already-submitted',
            courseId: 'COURSE_TEST',
            studentId: 'student-1',
            practiceDate: new Date(),
            goalText: 'Already submitted',
            tags: [],
            status: 'submitted',
          },
        });
        const res = await request(app.server)
          .post('/entries/entry-already-submitted/submit')
          .set('Authorization', `Bearer ${token}`)
          .send();
        expect(res.status).toBe(409);
        expect(res.body.error?.code).toBe('ENTRY_LOCKED');
      });

      it('should reject submitting an already reviewed entry', async () => {
        const token = await login('student');
        await prisma.practiceEntry.create({
          data: {
            id: 'entry-already-reviewed',
            courseId: 'COURSE_TEST',
            studentId: 'student-1',
            practiceDate: new Date(),
            goalText: 'Already reviewed',
            tags: [],
            status: 'reviewed',
          },
        });
        const res = await request(app.server)
          .post('/entries/entry-already-reviewed/submit')
          .set('Authorization', `Bearer ${token}`)
          .send();
        expect(res.status).toBe(409);
        expect(res.body.error?.code).toBe('ENTRY_LOCKED');
      });
    });

    describe('PATCH /entries/:entryId (submitted/reviewed)', () => {
      it('should reject editing a submitted entry', async () => {
        const token = await login('student');
        await prisma.practiceEntry.create({
          data: {
            id: 'entry-edit-submitted',
            courseId: 'COURSE_TEST',
            studentId: 'student-1',
            practiceDate: new Date(),
            goalText: 'Submitted',
            tags: [],
            status: 'submitted',
          },
        });
        const res = await request(app.server)
          .patch('/entries/entry-edit-submitted')
          .set('Authorization', `Bearer ${token}`)
          .send({ goalText: 'Changed' });
        expect(res.status).toBe(409);
        expect(res.body.error?.code).toBe('ENTRY_LOCKED');
      });

      it('should reject editing a reviewed entry', async () => {
        const token = await login('student');
        await prisma.practiceEntry.create({
          data: {
            id: 'entry-edit-reviewed',
            courseId: 'COURSE_TEST',
            studentId: 'student-1',
            practiceDate: new Date(),
            goalText: 'Reviewed',
            tags: [],
            status: 'reviewed',
          },
        });
        const res = await request(app.server)
          .patch('/entries/entry-edit-reviewed')
          .set('Authorization', `Bearer ${token}`)
          .send({ goalText: 'Changed' });
        expect(res.status).toBe(409);
        expect(res.body.error?.code).toBe('ENTRY_LOCKED');
      });

      it('should allow empty PATCH body on a submitted entry (no restricted fields)', async () => {
        const token = await login('student');
        await prisma.practiceEntry.create({
          data: {
            id: 'entry-empty-patch-submitted',
            courseId: 'COURSE_TEST',
            studentId: 'student-1',
            practiceDate: new Date(),
            goalText: 'Submitted',
            tags: [],
            status: 'submitted',
          },
        });
        const res = await request(app.server)
          .patch('/entries/entry-empty-patch-submitted')
          .set('Authorization', `Bearer ${token}`)
          .send({});
        expect(res.status).toBe(200);
      });
    });

    describe('POST /feedback (on reviewed entry)', () => {
      it('should allow posting additional feedback on a reviewed entry', async () => {
        const token = await login('teacher');
        await prisma.practiceEntry.create({
          data: {
            id: 'entry-reviewed-fb',
            courseId: 'COURSE_TEST',
            studentId: 'student-1',
            practiceDate: new Date(),
            goalText: 'Reviewed entry',
            tags: [],
            status: 'reviewed',
          },
        });
        const res = await request(app.server)
          .post('/feedback')
          .set('Authorization', `Bearer ${token}`)
          .send({
            targetType: 'entry',
            targetId: 'entry-reviewed-fb',
            status: 'needs_revision',
            commentsText: 'Additional feedback',
            markers: [],
          });
        // Entry is in 'reviewed' state (not 'draft'), so feedback should be allowed
        expect(res.status).toBe(201);
        expect(res.body.commentsText).toBe('Additional feedback');
      });

      it('should set entry status to reviewed after feedback', async () => {
        const token = await login('teacher');
        await prisma.practiceEntry.create({
          data: {
            id: 'entry-status-after-fb',
            courseId: 'COURSE_TEST',
            studentId: 'student-1',
            practiceDate: new Date(),
            goalText: 'Status after feedback',
            tags: [],
            status: 'submitted',
          },
        });
        await request(app.server).post('/feedback').set('Authorization', `Bearer ${token}`).send({
          targetType: 'entry',
          targetId: 'entry-status-after-fb',
          status: 'ok',
          commentsText: 'Reviewed!',
          markers: [],
        });
        const entry = await prisma.practiceEntry.findUnique({
          where: { id: 'entry-status-after-fb' },
        });
        expect(entry?.status).toBe('reviewed');
      });
    });

    describe('ID conflicts', () => {
      it('should return 409 when creating an entry with a duplicate ID', async () => {
        const token = await login('student');
        await prisma.practiceEntry.create({
          data: {
            id: 'duplicate-entry',
            courseId: 'COURSE_TEST',
            studentId: 'student-1',
            practiceDate: new Date(),
            goalText: 'Original',
            tags: [],
            status: 'draft',
          },
        });
        const res = await request(app.server)
          .post('/courses/COURSE_TEST/entries')
          .set('Authorization', `Bearer ${token}`)
          .send({
            id: 'duplicate-entry',
            practiceDate: new Date().toISOString(),
            goalText: 'Duplicate',
            tags: [],
          });
        expect(res.status).toBe(409);
        expect(res.body.error?.code).toBe('ID_CONFLICT');
      });

      it('should return 409 when creating an artifact with a duplicate ID', async () => {
        const token = await login('student');
        await prisma.practiceEntry.create({
          data: {
            id: 'entry-dup-art',
            courseId: 'COURSE_TEST',
            studentId: 'student-1',
            practiceDate: new Date(),
            goalText: 'Dup artifact',
            tags: [],
            status: 'draft',
          },
        });
        await prisma.artifact.create({
          data: {
            id: 'duplicate-artifact',
            entryId: 'entry-dup-art',
            type: 'audio',
            durationSeconds: 60,
          },
        });
        const res = await request(app.server)
          .post('/entries/entry-dup-art/artifacts')
          .set('Authorization', `Bearer ${token}`)
          .send({ id: 'duplicate-artifact', type: 'audio', durationSeconds: 120, sizeBytes: 1 });
        expect(res.status).toBe(409);
        expect(res.body.error?.code).toBe('ID_CONFLICT');
      });
    });
  });
});
