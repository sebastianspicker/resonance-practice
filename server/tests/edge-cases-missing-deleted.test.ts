// Verifies missing and tombstoned resources cannot be mutated or exposed through stale IDs.
import {
  app,
  describe,
  expect,
  it,
  login,
  prisma,
  request,
  installEdgeCaseSuite,
} from './support/edgeCaseTestHarness.js';

installEdgeCaseSuite();
describe('edge cases', () => {
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
        expect(res.status).toBe(410);
        expect(res.body.error?.code).toBe('ENTRY_DELETED');
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

    describe('POST /api/v1/artifact-sessions', () => {
      it('should return 404 when creating artifact for a non-existent entry', async () => {
        const token = await login('student');
        const res = await request(app.server)
          .post('/api/v1/artifact-sessions')
          .set('Authorization', `Bearer ${token}`)
          .send({
            operationId: 'missing-entry-operation',
            entryId: 'does-not-exist',
            artifactId: 'art-no-entry',
            type: 'audio',
            durationSeconds: 60,
            sizeBytes: 1,
            baseVersion: 1,
          });
        expect(res.status).toBe(404);
        expect(res.body.error?.code).toBe('ENTRY_NOT_FOUND');
      });

      it('should return 410 when creating artifact for a deleted entry', async () => {
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
          .post('/api/v1/artifact-sessions')
          .set('Authorization', `Bearer ${token}`)
          .send({
            operationId: 'deleted-entry-operation',
            entryId: 'entry-deleted-art',
            artifactId: 'art-for-deleted',
            type: 'audio',
            durationSeconds: 60,
            sizeBytes: 1,
            baseVersion: 1,
          });
        expect(res.status).toBe(410);
        expect(res.body.error?.code).toBe('ENTRY_DELETED');
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
