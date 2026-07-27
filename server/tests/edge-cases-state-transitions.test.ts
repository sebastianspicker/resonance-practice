// Covers invalid lifecycle transitions and idempotent repeats across entries and artifacts.
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

async function createEntry(id: string, goalText: string, status: 'submitted' | 'reviewed') {
  await prisma.practiceEntry.create({
    data: {
      id,
      courseId: 'COURSE_TEST',
      studentId: 'student-1',
      practiceDate: new Date(),
      goalText,
      tags: [],
      status,
    },
  });
}

async function submitEntry(token: string, entryId: string) {
  return request(app.server)
    .post(`/entries/${entryId}/submit`)
    .set('Authorization', `Bearer ${token}`)
    .send();
}

async function patchGoal(token: string, entryId: string, payload: Record<string, unknown>) {
  return request(app.server)
    .patch(`/entries/${entryId}`)
    .set('Authorization', `Bearer ${token}`)
    .send(payload);
}

describe('edge cases', () => {
  // ═══════════════════════════════════════════════════════════════════
  // Category 5: State Transitions
  // ═══════════════════════════════════════════════════════════════════

  describe('Category 5: State transitions', () => {
    describe('POST /entries/:entryId/submit', () => {
      it('should reject re-submitting an already submitted entry', async () => {
        const token = await login('student');
        await createEntry('entry-already-submitted', 'Already submitted', 'submitted');
        const res = await submitEntry(token, 'entry-already-submitted');
        expect(res.status).toBe(409);
        expect(res.body.error?.code).toBe('ENTRY_LOCKED');
      });

      it('should reject submitting an already reviewed entry', async () => {
        const token = await login('student');
        await createEntry('entry-already-reviewed', 'Already reviewed', 'reviewed');
        const res = await submitEntry(token, 'entry-already-reviewed');
        expect(res.status).toBe(409);
        expect(res.body.error?.code).toBe('ENTRY_LOCKED');
      });
    });

    describe('PATCH /entries/:entryId (submitted/reviewed)', () => {
      it('should reject editing a submitted entry', async () => {
        const token = await login('student');
        await createEntry('entry-edit-submitted', 'Submitted', 'submitted');
        const res = await patchGoal(token, 'entry-edit-submitted', { goalText: 'Changed' });
        expect(res.status).toBe(409);
        expect(res.body.error?.code).toBe('ENTRY_LOCKED');
      });

      it('should reject editing a reviewed entry', async () => {
        const token = await login('student');
        await createEntry('entry-edit-reviewed', 'Reviewed', 'reviewed');
        const res = await patchGoal(token, 'entry-edit-reviewed', { goalText: 'Changed' });
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
          .post('/api/v1/artifact-sessions')
          .set('Authorization', `Bearer ${token}`)
          .send({
            operationId: 'duplicate-artifact-operation',
            entryId: 'entry-dup-art',
            artifactId: 'duplicate-artifact',
            type: 'audio',
            durationSeconds: 120,
            sizeBytes: 1,
            baseVersion: 1,
          });
        expect(res.status).toBe(409);
        expect(res.body.error?.code).toBe('ID_CONFLICT');
      });
    });
  });
});
