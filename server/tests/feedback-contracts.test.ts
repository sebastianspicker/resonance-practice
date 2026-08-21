// Entry feedback must return each entry and artifact record exactly once, and IDs are idempotent.
import request from 'supertest';
import { describe, expect, it } from 'vitest';
import { app, installBasicSuite, login, prisma } from './support/testUtils.js';

describe('feedback completeness and idempotency', () => {
  installBasicSuite();

  it('creates a requested feedback ID once and returns entry and artifact feedback once', async () => {
    const entry = await prisma.practiceEntry.create({
      data: {
        id: 'feedback-entry',
        courseId: 'COURSE_TEST',
        studentId: 'student-1',
        practiceDate: new Date(),
        goalText: 'Listen',
        tags: [],
        status: 'submitted',
      },
    });
    const artifact = await prisma.artifact.create({
      data: {
        id: 'feedback-artifact',
        entryId: entry.id,
        type: 'audio',
        durationSeconds: 1,
        uploadState: 'uploaded',
      },
    });
    const teacher = await login('teacher');
    const entryFeedback = {
      id: 'feedback-entry-id',
      targetType: 'entry',
      targetId: entry.id,
      status: 'ok',
      commentsText: 'Keep this.',
      markers: [],
    };
    const first = await request(app.server)
      .post('/feedback')
      .set('authorization', `Bearer ${teacher}`)
      .send(entryFeedback);
    const retry = await request(app.server)
      .post('/feedback')
      .set('authorization', `Bearer ${teacher}`)
      .send(entryFeedback);
    const artifactFeedback = await request(app.server)
      .post('/feedback')
      .set('authorization', `Bearer ${teacher}`)
      .send({
        ...entryFeedback,
        id: 'feedback-artifact-id',
        targetType: 'artifact',
        targetId: artifact.id,
      });

    expect([first.status, retry.status, artifactFeedback.status]).toEqual([201, 200, 201]);
    expect(await prisma.feedback.count({ where: { id: entryFeedback.id } })).toBe(1);

    const student = await login('student');
    const response = await request(app.server)
      .get(`/entries/${entry.id}/feedback`)
      .set('authorization', `Bearer ${student}`);
    expect(response.status).toBe(200);
    expect(response.body.map((item: { id: string }) => item.id)).toEqual([
      'feedback-entry-id',
      'feedback-artifact-id',
    ]);
    expect(new Set(response.body.map((item: { id: string }) => item.id)).size).toBe(2);
  });
});
