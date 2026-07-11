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
  // Category 4: Missing / Deleted References
  // ═══════════════════════════════════════════════════════════════════

  describe('Category 4: Missing/deleted references', () => {
    describe('POST /feedback', () => {
      it('should return 404 when targeting a non-existent entry ID', async () => {
        const token = await login('teacher');
        const res = await request(app.server)
          .post('/feedback')
          .set('Authorization', `Bearer ${token}`)
          .send({
            targetType: 'entry',
            targetId: 'non-existent-entry-id',
            status: 'ok',
            commentsText: 'Feedback on nothing',
            markers: [],
          });
        expect(res.status).toBe(404);
        expect(res.body.error?.code).toBe('ENTRY_NOT_FOUND');
      });

      it('should return 404 when targeting a non-existent artifact ID', async () => {
        const token = await login('teacher');
        const res = await request(app.server)
          .post('/feedback')
          .set('Authorization', `Bearer ${token}`)
          .send({
            targetType: 'artifact',
            targetId: 'non-existent-artifact-id',
            status: 'ok',
            commentsText: 'Feedback on nothing',
            markers: [],
          });
        expect(res.status).toBe(404);
        expect(res.body.error?.code).toBe('ARTIFACT_NOT_FOUND');
      });

      it('should return 410 when targeting a soft-deleted entry', async () => {
        const token = await login('teacher');
        await prisma.practiceEntry.create({
          data: {
            id: 'entry-deleted-fb',
            courseId: 'COURSE_TEST',
            studentId: 'student-1',
            practiceDate: new Date(),
            goalText: 'Deleted entry',
            tags: [],
            status: 'submitted',
            deletedAt: new Date(),
          },
        });
        const res = await request(app.server)
          .post('/feedback')
          .set('Authorization', `Bearer ${token}`)
          .send({
            targetType: 'entry',
            targetId: 'entry-deleted-fb',
            status: 'ok',
            commentsText: 'Feedback on deleted',
            markers: [],
          });
        expect(res.status).toBe(410);
        expect(res.body.error?.code).toBe('ENTRY_DELETED');
      });

      it('should return 409 when targeting a draft entry (not yet submitted)', async () => {
        const token = await login('teacher');
        await prisma.practiceEntry.create({
          data: {
            id: 'entry-draft-fb',
            courseId: 'COURSE_TEST',
            studentId: 'student-1',
            practiceDate: new Date(),
            goalText: 'Still draft',
            tags: [],
            status: 'draft',
          },
        });
        const res = await request(app.server)
          .post('/feedback')
          .set('Authorization', `Bearer ${token}`)
          .send({
            targetType: 'entry',
            targetId: 'entry-draft-fb',
            status: 'ok',
            commentsText: 'Too early',
            markers: [],
          });
        expect(res.status).toBe(409);
        expect(res.body.error?.code).toBe('ENTRY_NOT_SUBMITTED');
      });
    });

    describe('POST /artifacts/:artifactId/presign', () => {
      it('should return 404 when presigning for a non-existent artifact', async () => {
        const token = await login('student');
        const res = await request(app.server)
          .post('/artifacts/non-existent-artifact/presign')
          .set('Authorization', `Bearer ${token}`)
          .send();
        expect(res.status).toBe(404);
        expect(res.body.error?.code).toBe('ARTIFACT_NOT_FOUND');
      });

      it('should return 410 when presigning for an artifact whose entry was deleted', async () => {
        const token = await login('student');
        await prisma.practiceEntry.create({
          data: {
            id: 'entry-del-presign',
            courseId: 'COURSE_TEST',
            studentId: 'student-1',
            practiceDate: new Date(),
            goalText: 'Deleted entry',
            tags: [],
            status: 'draft',
            deletedAt: new Date(),
          },
        });
        await prisma.artifact.create({
          data: {
            id: 'art-orphaned',
            entryId: 'entry-del-presign',
            type: 'audio',
            durationSeconds: 60,
          },
        });
        const res = await request(app.server)
          .post('/artifacts/art-orphaned/presign')
          .set('Authorization', `Bearer ${token}`)
          .send();
        expect(res.status).toBe(410);
        expect(res.body.error?.code).toBe('ENTRY_DELETED');
      });
    });

    describe('POST /entries/:entryId/artifacts', () => {
      it('should return 404 when creating artifact for a non-existent entry', async () => {
        const token = await login('student');
        const res = await request(app.server)
          .post('/entries/does-not-exist/artifacts')
          .set('Authorization', `Bearer ${token}`)
          .send({ id: 'art-no-entry', type: 'audio', durationSeconds: 60 });
        expect(res.status).toBe(404);
        expect(res.body.error?.code).toBe('ENTRY_NOT_FOUND');
      });

      it('should return 404 when creating artifact for a deleted entry', async () => {
        const token = await login('student');
        await prisma.practiceEntry.create({
          data: {
            id: 'entry-deleted-art',
            courseId: 'COURSE_TEST',
            studentId: 'student-1',
            practiceDate: new Date(),
            goalText: 'Deleted entry artifact',
            tags: [],
            status: 'draft',
            deletedAt: new Date(),
          },
        });
        const res = await request(app.server)
          .post('/entries/entry-deleted-art/artifacts')
          .set('Authorization', `Bearer ${token}`)
          .send({ id: 'art-for-deleted', type: 'audio', durationSeconds: 60 });
        expect(res.status).toBe(404);
        expect(res.body.error?.code).toBe('ENTRY_NOT_FOUND');
      });
    });

    describe('PATCH /entries/:entryId', () => {
      it('should return 404 when patching a non-existent entry', async () => {
        const token = await login('student');
        const res = await request(app.server)
          .patch('/entries/does-not-exist')
          .set('Authorization', `Bearer ${token}`)
          .send({ goalText: 'Updated' });
        expect(res.status).toBe(404);
        expect(res.body.error?.code).toBe('ENTRY_NOT_FOUND');
      });

      it('should return 410 when patching a deleted entry', async () => {
        const token = await login('student');
        await prisma.practiceEntry.create({
          data: {
            id: 'entry-deleted-patch',
            courseId: 'COURSE_TEST',
            studentId: 'student-1',
            practiceDate: new Date(),
            goalText: 'Will be deleted',
            tags: [],
            status: 'draft',
            deletedAt: new Date(),
          },
        });
        const res = await request(app.server)
          .patch('/entries/entry-deleted-patch')
          .set('Authorization', `Bearer ${token}`)
          .send({ goalText: 'Updated' });
        expect(res.status).toBe(410);
        expect(res.body.error?.code).toBe('ENTRY_DELETED');
      });
    });

    describe('DELETE /entries/:entryId', () => {
      it('should return 404 when deleting a non-existent entry', async () => {
        const token = await login('student');
        const res = await request(app.server)
          .delete('/entries/does-not-exist')
          .set('Authorization', `Bearer ${token}`)
          .send();
        expect(res.status).toBe(404);
        expect(res.body.error?.code).toBe('ENTRY_NOT_FOUND');
      });
    });
  });
});
