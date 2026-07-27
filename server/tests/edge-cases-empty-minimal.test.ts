// Covers empty and minimal payload boundaries that must fail or normalize predictably.
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

async function createSubmittedEntry(id: string) {
  await prisma.practiceEntry.create({
    data: {
      id,
      courseId: 'COURSE_TEST',
      studentId: 'student-1',
      practiceDate: new Date(),
      goalText: 'Feedback test',
      tags: [],
      status: 'submitted',
    },
  });
}

describe('edge cases', () => {
  // ═══════════════════════════════════════════════════════════════════
  // Category 1: Empty / Minimal Inputs
  // ═══════════════════════════════════════════════════════════════════

  describe('Category 1: Empty/minimal inputs', () => {
    describe('POST /courses/:courseId/entries', () => {
      it('should reject empty string goalText (minLength: 1)', async () => {
        const token = await login('student');
        const res = await request(app.server)
          .post('/courses/COURSE_TEST/entries')
          .set('Authorization', `Bearer ${token}`)
          .send({
            id: 'entry-empty-goal',
            practiceDate: new Date().toISOString(),
            goalText: '',
            tags: [],
          });
        // goalText now requires minLength: 1
        expect(res.status).toBe(400);
        expect(res.body.error.code).toBe('VALIDATION_ERROR');
      });

      it('should accept empty tags array', async () => {
        const token = await login('student');
        const res = await request(app.server)
          .post('/courses/COURSE_TEST/entries')
          .set('Authorization', `Bearer ${token}`)
          .send({
            id: 'entry-empty-tags',
            practiceDate: new Date().toISOString(),
            goalText: 'Some goal',
            tags: [],
          });
        expect(res.status).toBe(201);
        expect(res.body.tags).toEqual([]);
      });

      it('should accept zero durationSeconds', async () => {
        const token = await login('student');
        const res = await request(app.server)
          .post('/courses/COURSE_TEST/entries')
          .set('Authorization', `Bearer ${token}`)
          .send({
            id: 'entry-zero-dur',
            practiceDate: new Date().toISOString(),
            goalText: 'Zero duration test',
            tags: [],
            durationSeconds: 0,
          });
        expect(res.status).toBe(201);
        expect(res.body.durationSeconds).toBe(0);
      });

      it('should accept omitted durationSeconds (optional field)', async () => {
        const token = await login('student');
        const res = await request(app.server)
          .post('/courses/COURSE_TEST/entries')
          .set('Authorization', `Bearer ${token}`)
          .send({
            id: 'entry-no-dur',
            practiceDate: new Date().toISOString(),
            goalText: 'No duration',
            tags: [],
          });
        expect(res.status).toBe(201);
        expect(res.body.durationSeconds).toBeNull();
      });

      it('should accept omitted tags (defaults to empty array)', async () => {
        const token = await login('student');
        const res = await request(app.server)
          .post('/courses/COURSE_TEST/entries')
          .set('Authorization', `Bearer ${token}`)
          .send({
            id: 'entry-no-tags',
            practiceDate: new Date().toISOString(),
            goalText: 'No tags field',
          });
        expect(res.status).toBe(201);
        expect(res.body.tags).toEqual([]);
      });
    });

    describe('POST /entries/:entryId/submit', () => {
      it('should reject submission when entry has no artifacts', async () => {
        const token = await login('student');
        await prisma.practiceEntry.create({
          data: {
            id: 'entry-no-artifacts',
            courseId: 'COURSE_TEST',
            studentId: 'student-1',
            practiceDate: new Date(),
            goalText: 'No artifacts',
            tags: [],
            status: 'draft',
          },
        });
        const res = await request(app.server)
          .post('/entries/entry-no-artifacts/submit')
          .set('Authorization', `Bearer ${token}`)
          .send();
        expect(res.status).toBe(409);
        expect(res.body.error?.code).toBe('ARTIFACTS_NOT_UPLOADED');
      });

      it('should reject submission when artifacts exist but are not uploaded', async () => {
        const token = await login('student');
        await prisma.practiceEntry.create({
          data: {
            id: 'entry-pending-art',
            courseId: 'COURSE_TEST',
            studentId: 'student-1',
            practiceDate: new Date(),
            goalText: 'Pending artifact',
            tags: [],
            status: 'draft',
          },
        });
        await prisma.artifact.create({
          data: {
            id: 'art-pending',
            entryId: 'entry-pending-art',
            type: 'audio',
            durationSeconds: 60,
            uploadState: 'pending',
          },
        });
        const res = await request(app.server)
          .post('/entries/entry-pending-art/submit')
          .set('Authorization', `Bearer ${token}`)
          .send();
        expect(res.status).toBe(409);
        expect(res.body.error?.code).toBe('ARTIFACTS_NOT_UPLOADED');
      });

      it('should reject teaching lesson submission without consent metadata', async () => {
        const token = await login('student');
        await prisma.practiceEntry.create({
          data: {
            id: 'entry-teaching-no-consent',
            courseId: 'COURSE_TEST',
            studentId: 'student-1',
            kind: 'teaching_lesson',
            practiceDate: new Date(),
            goalText: 'Teach a call-and-response rhythm',
            tags: ['lehramt'],
            status: 'draft',
          },
        });
        await prisma.artifact.create({
          data: {
            id: 'art-teaching-uploaded',
            entryId: 'entry-teaching-no-consent',
            type: 'video',
            durationSeconds: 120,
            uploadState: 'uploaded',
            storageKey: 'artifacts/entry-teaching-no-consent/art-teaching-uploaded',
          },
        });
        const res = await request(app.server)
          .post('/entries/entry-teaching-no-consent/submit')
          .set('Authorization', `Bearer ${token}`)
          .send();
        expect(res.status).toBe(409);
        expect(res.body.error?.code).toBe('CONSENT_REQUIRED');
      });

      it('should reject teaching lesson submission without an uploaded video artifact', async () => {
        const token = await login('student');
        await prisma.practiceEntry.create({
          data: {
            id: 'entry-teaching-audio-only',
            courseId: 'COURSE_TEST',
            studentId: 'student-1',
            kind: 'teaching_lesson',
            practiceDate: new Date(),
            goalText: 'Reflect on rhythm modelling',
            tags: ['lehramt'],
            status: 'draft',
            consentConfirmedAt: new Date(),
            consentScope: 'private_course_review',
          },
        });
        await prisma.artifact.create({
          data: {
            id: 'art-teaching-audio-only',
            entryId: 'entry-teaching-audio-only',
            type: 'audio',
            durationSeconds: 120,
            uploadState: 'uploaded',
            storageKey: 'artifacts/entry-teaching-audio-only/art-teaching-audio-only',
          },
        });
        const res = await request(app.server)
          .post('/entries/entry-teaching-audio-only/submit')
          .set('Authorization', `Bearer ${token}`)
          .send();

        expect(res.status).toBe(409);
        expect(res.body.error?.code).toBe('ARTIFACTS_NOT_UPLOADED');
      });
    });

    describe('POST /feedback', () => {
      it('should accept feedback with empty markers array', async () => {
        const token = await login('teacher');
        await createSubmittedEntry('entry-fb-empty-markers');
        const res = await request(app.server)
          .post('/feedback')
          .set('Authorization', `Bearer ${token}`)
          .send({
            targetType: 'entry',
            targetId: 'entry-fb-empty-markers',
            status: 'ok',
            commentsText: 'Good work',
            markers: [],
          });
        expect(res.status).toBe(201);
        expect(res.body.markers).toEqual([]);
      });

      it('should accept feedback when markers field is omitted (defaults to empty)', async () => {
        const token = await login('teacher');
        await createSubmittedEntry('entry-fb-no-markers');
        const res = await request(app.server)
          .post('/feedback')
          .set('Authorization', `Bearer ${token}`)
          .send({
            targetType: 'entry',
            targetId: 'entry-fb-no-markers',
            status: 'ok',
            commentsText: 'Looks fine',
          });
        expect(res.status).toBe(201);
        expect(res.body.markers).toEqual([]);
      });

      it('should accept minimal commentsText (single character)', async () => {
        const token = await login('teacher');
        await createSubmittedEntry('entry-fb-min-comment');
        const res = await request(app.server)
          .post('/feedback')
          .set('Authorization', `Bearer ${token}`)
          .send({
            targetType: 'entry',
            targetId: 'entry-fb-min-comment',
            status: 'ok',
            commentsText: 'x',
            markers: [],
          });
        expect(res.status).toBe(201);
        expect(res.body.commentsText).toBe('x');
      });
    });
  });
});
