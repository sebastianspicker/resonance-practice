// Exercises documented maximum sizes, counts, and identifier lengths at their exact limits.
import { beforeEach } from 'vitest';
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

async function postFeedback(token: string, targetId: string, payload: Record<string, unknown>) {
  return request(app.server)
    .post('/feedback')
    .set('Authorization', `Bearer ${token}`)
    .send({ targetType: 'entry', targetId, status: 'ok', ...payload });
}

async function postEntry(token: string, payload: Record<string, unknown>) {
  return request(app.server)
    .post('/courses/COURSE_TEST/entries')
    .set('Authorization', `Bearer ${token}`)
    .send({ practiceDate: new Date().toISOString(), tags: [], ...payload });
}

async function postEntryWithDuration(id: string, goalText: string, durationSeconds: number) {
  const token = await login('student');
  return postEntry(token, { id, goalText, durationSeconds });
}

function submittedFeedbackEntry() {
  return {
    courseId: 'COURSE_TEST',
    studentId: 'student-1',
    practiceDate: new Date(),
    goalText: 'Boundary test',
    tags: [],
    status: 'submitted' as const,
  };
}

describe('edge cases', () => {
  // ═══════════════════════════════════════════════════════════════════
  // Category 2: Maximum / Boundary Inputs
  // ═══════════════════════════════════════════════════════════════════

  describe('Category 2: Maximum/boundary inputs', () => {
    describe('POST /courses/:courseId/entries', () => {
      it('should accept ID at max length (128 chars)', async () => {
        const token = await login('student');
        const maxId = 'a'.repeat(128);
        const res = await postEntry(token, { id: maxId, goalText: 'Max ID test' });
        expect(res.status).toBe(201);
        expect(res.body.id).toBe(maxId);
      });

      it('should reject ID exceeding max length (129 chars)', async () => {
        const token = await login('student');
        const tooLongId = 'a'.repeat(129);
        const res = await postEntry(token, { id: tooLongId, goalText: 'Too long ID' });
        expect(res.status).toBe(400);
        expect(res.body.error?.code).toBe('VALIDATION_ERROR');
      });

      it('should accept tags at max count (30)', async () => {
        const token = await login('student');
        const tags = Array.from({ length: 30 }, (_, i) => `tag-${i}`);
        const res = await postEntry(token, {
          id: 'entry-30-tags',
          goalText: 'Max tags test',
          tags,
        });
        expect(res.status).toBe(201);
        expect(res.body.tags).toHaveLength(30);
      });

      it('should accept goalText at max length (10000 chars)', async () => {
        const token = await login('student');
        const goalText = 'g'.repeat(10000);
        const res = await postEntry(token, { id: 'entry-max-goal', goalText });
        expect(res.status).toBe(201);
        expect(res.body.goalText).toHaveLength(10000);
      });

      it('should reject goalText exceeding max length (10001 chars)', async () => {
        const token = await login('student');
        const goalText = 'g'.repeat(10001);
        const res = await postEntry(token, { id: 'entry-too-long-goal', goalText });
        expect(res.status).toBe(400);
        expect(res.body.error?.code).toBe('VALIDATION_ERROR');
      });

      describe('durationSeconds limits', () => {
        it('should accept durationSeconds at max (28800)', async () => {
          const res = await postEntryWithDuration('entry-dur-28800', 'Max duration', 28800);
          expect(res.status).toBe(201);
          expect(res.body.durationSeconds).toBe(28800);
        });

        it('should reject durationSeconds just above max (28801)', async () => {
          const res = await postEntryWithDuration('entry-dur-28801', 'Over max duration', 28801);
          expect(res.status).toBe(400);
          expect(res.body.error?.code).toBe('VALIDATION_ERROR');
        });
      });
    });

    describe('POST /feedback', () => {
      let entryId: string;

      beforeEach(async () => {
        entryId = 'entry-fb-boundary';
        await prisma.practiceEntry.create({
          data: { id: entryId, ...submittedFeedbackEntry() },
        });
      });

      it('should accept marker count at exactly 50', async () => {
        const token = await login('teacher');
        const markers = Array.from({ length: 50 }, (_, i) => ({
          timeSeconds: i * 10,
          text: `Marker ${i}`,
        }));
        const res = await postFeedback(token, entryId, {
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
        const res = await postFeedback(token, entryId, {
          commentsText: 'With 51 markers',
          markers,
        });
        expect(res.status).toBe(400);
        expect(res.body.error?.code).toBe('VALIDATION_ERROR');
      });

      it('should accept marker timeSeconds at boundary 0', async () => {
        const token = await login('teacher');
        const res = await postFeedback(token, entryId, {
          commentsText: 'Boundary marker',
          markers: [{ timeSeconds: 0, text: 'At start' }],
        });
        expect(res.status).toBe(201);
        expect(res.body.markers[0].timeSeconds).toBe(0);
      });

      it('should accept marker timeSeconds at boundary 28800', async () => {
        const token = await login('teacher');
        const res = await postFeedback(token, entryId, {
          commentsText: 'Max time marker',
          markers: [{ timeSeconds: 28800, text: 'At max' }],
        });
        expect(res.status).toBe(201);
        expect(res.body.markers[0].timeSeconds).toBe(28800);
      });

      it('should reject marker timeSeconds at 28801', async () => {
        const token = await login('teacher');
        const res = await postFeedback(token, entryId, {
          commentsText: 'Over max time marker',
          markers: [{ timeSeconds: 28801, text: 'Over max' }],
        });
        expect(res.status).toBe(400);
        expect(res.body.error?.code).toBe('VALIDATION_ERROR');
      });

      it('should reject negative marker timeSeconds', async () => {
        const token = await login('teacher');
        const res = await postFeedback(token, entryId, {
          commentsText: 'Negative time',
          markers: [{ timeSeconds: -1, text: 'Negative' }],
        });
        expect(res.status).toBe(400);
        expect(res.body.error?.code).toBe('VALIDATION_ERROR');
      });

      it('should accept marker text at max length (1000 chars)', async () => {
        const token = await login('teacher');
        const res = await postFeedback(token, entryId, {
          commentsText: 'Max marker text',
          markers: [{ timeSeconds: 10, text: 'm'.repeat(1000) }],
        });
        expect(res.status).toBe(201);
        expect(res.body.markers[0].text).toHaveLength(1000);
      });

      it('should accept commentsText at max length (10000 chars)', async () => {
        const token = await login('teacher');
        const res = await postFeedback(token, entryId, {
          commentsText: 'c'.repeat(10000),
          markers: [],
        });
        expect(res.status).toBe(201);
        expect(res.body.commentsText).toHaveLength(10000);
      });
    });

    describe('POST /api/v1/artifact-sessions', () => {
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
          .post('/api/v1/artifact-sessions')
          .set('Authorization', `Bearer ${token}`)
          .send({
            operationId: 'max-artifact-operation',
            entryId: 'entry-art-maxid',
            artifactId: maxId,
            type: 'audio',
            durationSeconds: 60,
            sizeBytes: 1,
            baseVersion: 1,
          });
        expect(res.status).toBe(200);
        expect(res.body.artifact.id).toBe(maxId);
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
          .post('/api/v1/artifact-sessions')
          .set('Authorization', `Bearer ${token}`)
          .send({
            operationId: 'zero-duration-operation',
            entryId: 'entry-art-zero-dur',
            artifactId: 'art-zero-dur',
            type: 'audio',
            durationSeconds: 0,
            sizeBytes: 1,
            baseVersion: 1,
          });
        expect(res.status).toBe(200);
        expect(res.body.artifact.durationSeconds).toBe(0);
      });
    });
  });
});
