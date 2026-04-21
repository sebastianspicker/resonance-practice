import request from 'supertest';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import {
  app,
  getAccessToken,
  prisma,
  resetDb,
  seedBasic,
  setupApp,
  teardownApp,
} from './testUtils.js';

describe('GET /entries/:entryId/feedback completeness', () => {
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

  it('returns both entry-level and artifact-level feedback linked to the entry', async () => {
    await prisma.practiceEntry.create({
      data: {
        id: 'entry-feedback-parent',
        courseId: 'COURSE_TEST',
        studentId: 'student-1',
        practiceDate: new Date('2025-04-01T10:00:00.000Z'),
        goalText: 'Feedback completeness',
        tags: [],
        status: 'submitted',
      },
    });

    await prisma.artifact.create({
      data: {
        id: 'artifact-feedback-child',
        entryId: 'entry-feedback-parent',
        type: 'audio',
        durationSeconds: 60,
        uploadState: 'uploaded',
      },
    });

    await prisma.feedback.create({
      data: {
        id: 'feedback-entry',
        targetType: 'entry',
        targetId: 'entry-feedback-parent',
        teacherId: 'teacher-1',
        entryId: 'entry-feedback-parent',
        status: 'ok',
        commentsText: 'Entry-level note',
      },
    });

    await prisma.feedback.create({
      data: {
        id: 'feedback-artifact',
        targetType: 'artifact',
        targetId: 'artifact-feedback-child',
        teacherId: 'teacher-1',
        entryId: 'entry-feedback-parent',
        status: 'needs_revision',
        commentsText: 'Artifact-level note',
      },
    });

    const token = await getAccessToken('student', { userId: 'student-1' });
    const res = await request(app.server)
      .get('/entries/entry-feedback-parent/feedback')
      .set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(200);
    expect(res.body.map((item: { id: string }) => item.id)).toEqual([
      'feedback-entry',
      'feedback-artifact',
    ]);
    expect(res.body[1].targetType).toBe('artifact');
  });
});
