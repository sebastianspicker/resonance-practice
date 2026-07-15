import request from 'supertest';
import { beforeAll, afterAll, beforeEach, describe, expect, it } from 'vitest';
import { DeleteObjectCommand } from '@aws-sdk/client-s3';
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

describe('acl', () => {
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

  it('prevents student from reading other student entries', async () => {
    const otherStudent = await prisma.user.create({
      data: { id: 'student-2', displayName: 'Other Student', globalRole: 'student' },
    });
    await prisma.membership.create({
      data: { userId: otherStudent.id, courseId: 'COURSE_TEST', roleInCourse: 'student' },
    });

    await prisma.practiceEntry.create({
      data: {
        id: 'entry-foreign',
        courseId: 'COURSE_TEST',
        studentId: otherStudent.id,
        practiceDate: new Date(),
        goalText: 'Other student entry',
        tags: ['tag'],
        status: 'draft',
      },
    });

    const token = await login('student');
    const res = await request(app.server)
      .get('/courses/COURSE_TEST/entries')
      .set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(200);
    expect(res.body.items.find((e: any) => e.id === 'entry-foreign')).toBeUndefined();
  });

  it('allows teacher to view review queue', async () => {
    await prisma.practiceEntry.create({
      data: {
        id: 'entry-submitted',
        courseId: 'COURSE_TEST',
        studentId: 'student-1',
        practiceDate: new Date(),
        goalText: 'Submitted entry',
        tags: ['tag'],
        status: 'submitted',
      },
    });

    const token = await login('teacher');
    const res = await request(app.server)
      .get('/courses/COURSE_TEST/review-queue')
      .set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(200);
    expect(res.body.items.length).toBe(1);
    expect(res.body.nextCursor).toBeNull();
  });

  it('returns review queue sorted by practiceDate desc then createdAt desc', async () => {
    await prisma.practiceEntry.create({
      data: {
        id: 'entry-old-practice',
        courseId: 'COURSE_TEST',
        studentId: 'student-1',
        practiceDate: new Date('2025-01-01T10:00:00.000Z'),
        createdAt: new Date('2025-01-01T09:00:00.000Z'),
        goalText: 'Older practice',
        tags: ['tag'],
        status: 'submitted',
      },
    });
    await prisma.practiceEntry.create({
      data: {
        id: 'entry-new-practice',
        courseId: 'COURSE_TEST',
        studentId: 'student-1',
        practiceDate: new Date('2025-01-02T10:00:00.000Z'),
        createdAt: new Date('2025-01-01T08:00:00.000Z'),
        goalText: 'Newer practice',
        tags: ['tag'],
        status: 'submitted',
      },
    });
    await prisma.practiceEntry.create({
      data: {
        id: 'entry-same-practice-newer-created',
        courseId: 'COURSE_TEST',
        studentId: 'student-1',
        practiceDate: new Date('2025-01-02T10:00:00.000Z'),
        createdAt: new Date('2025-01-02T11:00:00.000Z'),
        goalText: 'Tie-breaker newer createdAt',
        tags: ['tag'],
        status: 'submitted',
      },
    });

    const token = await login('teacher');
    const res = await request(app.server)
      .get('/courses/COURSE_TEST/review-queue')
      .set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(200);
    expect(res.body.items.map((entry: any) => entry.id)).toEqual([
      'entry-same-practice-newer-created',
      'entry-new-practice',
      'entry-old-practice',
    ]);
  });

  it('blocks access to deleted entries', async () => {
    const entry = await prisma.practiceEntry.create({
      data: {
        id: 'entry-deleted',
        courseId: 'COURSE_TEST',
        studentId: 'student-1',
        practiceDate: new Date(),
        goalText: 'Deleted entry',
        tags: ['tag'],
        status: 'draft',
        deletedAt: new Date(),
      },
    });

    const token = await login('student');
    const res = await request(app.server)
      .patch(`/entries/${entry.id}`)
      .set('Authorization', `Bearer ${token}`)
      .send({ goalText: 'Should fail' });

    expect(res.status).toBe(410);
  });

  it('rejects invalid practice dates', async () => {
    const token = await login('student');
    const res = await request(app.server)
      .post('/courses/COURSE_TEST/entries')
      .set('Authorization', `Bearer ${token}`)
      .send({
        id: 'entry-bad-date',
        practiceDate: 'not-a-date',
        goalText: 'Bad date',
        tags: [],
      });

    expect(res.status).toBe(400);
  });

  it('rejects non-string tags', async () => {
    const token = await login('student');
    const res = await request(app.server)
      .post('/courses/COURSE_TEST/entries')
      .set('Authorization', `Bearer ${token}`)
      .send({
        id: 'entry-bad-tags',
        practiceDate: new Date().toISOString(),
        goalText: 'Bad tags',
        tags: ['ok', 123],
      });

    expect(res.status).toBe(400);
  });

  it('hard deletes entry data, retains a minimal ID tombstone, and queues storage cleanup', async () => {
    s3Mock.on(DeleteObjectCommand).resolves({});

    const entry = await prisma.practiceEntry.create({
      data: {
        id: 'entry-hard-delete',
        courseId: 'COURSE_TEST',
        studentId: 'student-1',
        practiceDate: new Date(),
        goalText: 'Delete me',
        tags: ['tag'],
        status: 'draft',
      },
    });

    const artifact = await prisma.artifact.create({
      data: {
        id: 'artifact-hard-delete',
        entryId: entry.id,
        type: 'audio',
        durationSeconds: 10,
        uploadState: 'uploaded',
        storageKey: 'artifacts/entry-hard-delete/artifact-hard-delete',
      },
    });

    await prisma.feedback.create({
      data: {
        id: 'fb_entry_1',
        targetType: 'entry',
        targetId: entry.id,
        teacherId: 'teacher-1',
        status: 'ok',
        commentsText: 'Good job',
        markers: {
          create: [{ id: 'mk_entry_1', timeSeconds: 1, text: 'nice' }],
        },
      },
    });

    await prisma.feedback.create({
      data: {
        id: 'fb_artifact_1',
        targetType: 'artifact',
        targetId: artifact.id,
        teacherId: 'teacher-1',
        status: 'ok',
        commentsText: 'Nice sound',
        markers: {
          create: [{ id: 'mk_artifact_1', timeSeconds: 2, text: 'tone' }],
        },
      },
    });

    const token = await login('student');
    const res = await request(app.server)
      .delete(`/entries/${entry.id}`)
      .set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(204);
    expect(s3Mock.commandCalls(DeleteObjectCommand)).toHaveLength(0);

    const entryAfter = await prisma.practiceEntry.findUnique({ where: { id: entry.id } });
    const artifactAfter = await prisma.artifact.findUnique({ where: { id: artifact.id } });
    const feedbackAfter = await prisma.feedback.findMany({ where: { targetId: entry.id } });
    const artifactFeedbackAfter = await prisma.feedback.findMany({
      where: { targetId: artifact.id },
    });
    const markerAfter = await prisma.marker.findUnique({ where: { id: 'mk_entry_1' } });
    const tombstone = await prisma.deletedEntryTombstone.findUnique({ where: { id: entry.id } });
    const deletionJobs = await prisma.storageDeletionJob.findMany({ where: { entryId: entry.id } });

    expect(entryAfter).toBeNull();
    expect(tombstone).toMatchObject({ id: entry.id });
    expect(deletionJobs.map((job) => job.storageKey)).toEqual([
      'artifacts/entry-hard-delete/artifact-hard-delete',
    ]);
    expect(artifactAfter).toBeNull();
    expect(feedbackAfter.length).toBe(0);
    expect(artifactFeedbackAfter.length).toBe(0);
    expect(markerAfter).toBeNull();

    const staleRecreate = await request(app.server)
      .post('/courses/COURSE_TEST/entries')
      .set('Authorization', `Bearer ${token}`)
      .send({
        id: entry.id,
        practiceDate: entry.practiceDate.toISOString(),
        goalText: entry.goalText,
        tags: entry.tags,
      });
    expect(staleRecreate.status).toBe(410);
    expect(staleRecreate.body.error?.code).toBe('ENTRY_DELETED');
  });

  it('cascade delete handles multiple artifacts atomically (bug #20)', async () => {
    s3Mock.reset();

    const entry = await prisma.practiceEntry.create({
      data: {
        id: 'entry-multi-artifact',
        courseId: 'COURSE_TEST',
        studentId: 'student-1',
        practiceDate: new Date(),
        goalText: 'Multi artifact delete test',
        tags: [],
        status: 'draft',
      },
    });

    const artifact1 = await prisma.artifact.create({
      data: {
        id: 'artifact-multi-1',
        entryId: entry.id,
        type: 'audio',
        durationSeconds: 10,
        uploadState: 'uploaded',
        storageKey: 'artifacts/entry-multi-artifact/artifact-multi-1',
      },
    });

    const artifact2 = await prisma.artifact.create({
      data: {
        id: 'artifact-multi-2',
        entryId: entry.id,
        type: 'video',
        durationSeconds: 20,
        uploadState: 'uploaded',
        storageKey: 'artifacts/entry-multi-artifact/artifact-multi-2',
      },
    });

    // Add feedback on each artifact
    await prisma.feedback.create({
      data: {
        id: 'fb_multi_1',
        targetType: 'artifact',
        targetId: artifact1.id,
        teacherId: 'teacher-1',
        status: 'ok',
        commentsText: 'Feedback on artifact 1',
      },
    });

    await prisma.feedback.create({
      data: {
        id: 'fb_multi_2',
        targetType: 'artifact',
        targetId: artifact2.id,
        teacherId: 'teacher-1',
        status: 'needs_revision',
        commentsText: 'Feedback on artifact 2',
      },
    });

    const token = await login('student');
    const res = await request(app.server)
      .delete(`/entries/${entry.id}`)
      .set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(204);

    // Object deletion is durable and asynchronous, not part of the request.
    expect(s3Mock.commandCalls(DeleteObjectCommand)).toHaveLength(0);

    const entryAfter = await prisma.practiceEntry.findUnique({ where: { id: entry.id } });
    const tombstone = await prisma.deletedEntryTombstone.findUnique({ where: { id: entry.id } });
    const deletionJobs = await prisma.storageDeletionJob.findMany({ where: { entryId: entry.id } });
    const artifact1After = await prisma.artifact.findUnique({ where: { id: artifact1.id } });
    const artifact2After = await prisma.artifact.findUnique({ where: { id: artifact2.id } });
    const feedbackAfter = await prisma.feedback.findMany({
      where: { targetId: { in: [artifact1.id, artifact2.id] } },
    });

    expect(entryAfter).toBeNull();
    expect(tombstone).toMatchObject({ id: entry.id });
    expect(deletionJobs.map((job) => job.storageKey).sort()).toEqual(
      [artifact1.storageKey, artifact2.storageKey].sort()
    );
    expect(artifact1After).toBeNull();
    expect(artifact2After).toBeNull();
    expect(feedbackAfter.length).toBe(0);
  });

  it('uses course role (not global role) for submit authorization', async () => {
    const mixedUser = await prisma.user.create({
      data: { id: 'mixed-role-user', displayName: 'Mixed Role', globalRole: 'teacher' },
    });
    await prisma.membership.create({
      data: { userId: mixedUser.id, courseId: 'COURSE_TEST', roleInCourse: 'student' },
    });

    await prisma.practiceEntry.create({
      data: {
        id: 'entry-mixed-role',
        courseId: 'COURSE_TEST',
        studentId: mixedUser.id,
        practiceDate: new Date(),
        goalText: 'Submit me',
        tags: ['tag'],
        status: 'draft',
      },
    });
    await prisma.artifact.create({
      data: {
        id: 'artifact-mixed-role',
        entryId: 'entry-mixed-role',
        type: 'audio',
        durationSeconds: 15,
        uploadState: 'uploaded',
        storageKey: 'artifacts/entry-mixed-role/artifact-mixed-role',
      },
    });

    const token = await getAccessToken('teacher', { userId: mixedUser.id });
    const res = await request(app.server)
      .post('/entries/entry-mixed-role/submit')
      .set('Authorization', `Bearer ${token}`)
      .send();

    expect(res.status).toBe(200);
    expect(res.body.status).toBe('submitted');
  });

  it('rejects invalid artifact type', async () => {
    const entry = await prisma.practiceEntry.create({
      data: {
        id: 'entry-bad-artifact',
        courseId: 'COURSE_TEST',
        studentId: 'student-1',
        practiceDate: new Date(),
        goalText: 'Invalid artifact',
        tags: ['tag'],
        status: 'draft',
      },
    });

    const token = await login('student');
    const res = await request(app.server)
      .post(`/entries/${entry.id}/artifacts`)
      .set('Authorization', `Bearer ${token}`)
      .send({ id: 'artifact-bad', type: 'image', durationSeconds: 5, sizeBytes: 1 });

    expect(res.status).toBe(400);
  });

  it('rejects invalid feedback status', async () => {
    const entry = await prisma.practiceEntry.create({
      data: {
        id: 'entry-bad-feedback',
        courseId: 'COURSE_TEST',
        studentId: 'student-1',
        practiceDate: new Date(),
        goalText: 'Feedback target',
        tags: ['tag'],
        status: 'submitted',
      },
    });

    const token = await login('teacher');
    const res = await request(app.server)
      .post('/feedback')
      .set('Authorization', `Bearer ${token}`)
      .send({
        targetType: 'entry',
        targetId: entry.id,
        status: 'invalid_status',
        commentsText: 'test',
        markers: [],
      });

    expect(res.status).toBe(400);
  });

  it('rejects feedback with non-existent entry targetId (bug #44)', async () => {
    const token = await login('teacher');
    const res = await request(app.server)
      .post('/feedback')
      .set('Authorization', `Bearer ${token}`)
      .send({
        targetType: 'entry',
        targetId: 'non-existent-entry-id',
        status: 'ok',
        commentsText: 'This should fail',
        markers: [],
      });

    expect(res.status).toBe(404);
  });

  it('rejects feedback with non-existent artifact targetId (bug #44)', async () => {
    const token = await login('teacher');
    const res = await request(app.server)
      .post('/feedback')
      .set('Authorization', `Bearer ${token}`)
      .send({
        targetType: 'artifact',
        targetId: 'non-existent-artifact-id',
        status: 'ok',
        commentsText: 'This should fail',
        markers: [],
      });

    expect(res.status).toBe(404);
  });

  it('marks entry as reviewed when teacher posts feedback directly on entry', async () => {
    const entry = await prisma.practiceEntry.create({
      data: {
        id: 'entry-review-status',
        courseId: 'COURSE_TEST',
        studentId: 'student-1',
        practiceDate: new Date(),
        goalText: 'Review target',
        tags: ['tag'],
        status: 'submitted',
      },
    });

    const token = await login('teacher');
    const res = await request(app.server)
      .post('/feedback')
      .set('Authorization', `Bearer ${token}`)
      .send({
        targetType: 'entry',
        targetId: entry.id,
        status: 'ok',
        commentsText: 'Looks good',
        markers: [],
      });

    expect(res.status).toBe(201);

    const updatedEntry = await prisma.practiceEntry.findUnique({ where: { id: entry.id } });
    expect(updatedEntry?.status).toBe('reviewed');
  });

  it('treats repeated client feedback ids as idempotent retries', async () => {
    const entry = await prisma.practiceEntry.create({
      data: {
        id: 'entry-idempotent-feedback',
        courseId: 'COURSE_TEST',
        studentId: 'student-1',
        practiceDate: new Date(),
        goalText: 'Retry target',
        tags: ['tag'],
        status: 'submitted',
      },
    });

    const token = await login('teacher');
    const body = {
      id: 'feedback_retry_1',
      targetType: 'entry',
      targetId: entry.id,
      status: 'ok',
      commentsText: 'Stable feedback',
      markers: [{ timeSeconds: 3, text: 'steady' }],
    };

    const first = await request(app.server)
      .post('/feedback')
      .set('Authorization', `Bearer ${token}`)
      .send(body);
    const second = await request(app.server)
      .post('/feedback')
      .set('Authorization', `Bearer ${token}`)
      .send(body);

    expect(first.status).toBe(201);
    expect(second.status).toBe(200);
    expect(second.body.id).toBe('feedback_retry_1');

    const feedbackRows = await prisma.feedback.findMany({ where: { id: 'feedback_retry_1' } });
    const markerRows = await prisma.marker.findMany({ where: { feedbackId: 'feedback_retry_1' } });
    expect(feedbackRows).toHaveLength(1);
    expect(markerRows).toHaveLength(1);
  });

  it('rejects reused client feedback ids when status changes', async () => {
    const entry = await prisma.practiceEntry.create({
      data: {
        id: 'entry-feedback-status-conflict',
        courseId: 'COURSE_TEST',
        studentId: 'student-1',
        practiceDate: new Date(),
        goalText: 'Retry target',
        tags: ['tag'],
        status: 'submitted',
      },
    });
    const token = await login('teacher');
    const body = {
      id: 'feedback_retry_status_conflict',
      targetType: 'entry',
      targetId: entry.id,
      status: 'ok',
      commentsText: 'Stable feedback',
      markers: [{ timeSeconds: 3, text: 'steady' }],
    };

    const first = await request(app.server)
      .post('/feedback')
      .set('Authorization', `Bearer ${token}`)
      .send(body);
    const second = await request(app.server)
      .post('/feedback')
      .set('Authorization', `Bearer ${token}`)
      .send({ ...body, status: 'needs_revision' });

    expect(first.status).toBe(201);
    expect(second.status).toBe(409);
    expect(second.body.error?.code).toBe('ID_CONFLICT');
  });

  it('rejects reused client feedback ids when comments change', async () => {
    const entry = await prisma.practiceEntry.create({
      data: {
        id: 'entry-feedback-comment-conflict',
        courseId: 'COURSE_TEST',
        studentId: 'student-1',
        practiceDate: new Date(),
        goalText: 'Retry target',
        tags: ['tag'],
        status: 'submitted',
      },
    });
    const token = await login('teacher');
    const body = {
      id: 'feedback_retry_comment_conflict',
      targetType: 'entry',
      targetId: entry.id,
      status: 'ok',
      commentsText: 'Stable feedback',
      markers: [{ timeSeconds: 3, text: 'steady' }],
    };

    const first = await request(app.server)
      .post('/feedback')
      .set('Authorization', `Bearer ${token}`)
      .send(body);
    const second = await request(app.server)
      .post('/feedback')
      .set('Authorization', `Bearer ${token}`)
      .send({ ...body, commentsText: 'Changed feedback' });

    expect(first.status).toBe(201);
    expect(second.status).toBe(409);
    expect(second.body.error?.code).toBe('ID_CONFLICT');
  });

  it('rejects reused client feedback ids when markers change', async () => {
    const entry = await prisma.practiceEntry.create({
      data: {
        id: 'entry-feedback-marker-conflict',
        courseId: 'COURSE_TEST',
        studentId: 'student-1',
        practiceDate: new Date(),
        goalText: 'Retry target',
        tags: ['tag'],
        status: 'submitted',
      },
    });
    const token = await login('teacher');
    const body = {
      id: 'feedback_retry_marker_conflict',
      targetType: 'entry',
      targetId: entry.id,
      status: 'ok',
      commentsText: 'Stable feedback',
      markers: [{ timeSeconds: 3, text: 'steady' }],
    };

    const first = await request(app.server)
      .post('/feedback')
      .set('Authorization', `Bearer ${token}`)
      .send(body);
    const second = await request(app.server)
      .post('/feedback')
      .set('Authorization', `Bearer ${token}`)
      .send({ ...body, markers: [{ timeSeconds: 4, text: 'steady' }] });

    expect(first.status).toBe(201);
    expect(second.status).toBe(409);
    expect(second.body.error?.code).toBe('ID_CONFLICT');
  });

  it('marks parent entry as reviewed when teacher posts feedback on artifact', async () => {
    const entry = await prisma.practiceEntry.create({
      data: {
        id: 'entry-artifact-review-status',
        courseId: 'COURSE_TEST',
        studentId: 'student-1',
        practiceDate: new Date(),
        goalText: 'Artifact review target',
        tags: ['tag'],
        status: 'submitted',
      },
    });
    const artifact = await prisma.artifact.create({
      data: {
        id: 'artifact-review-status',
        entryId: entry.id,
        type: 'audio',
        durationSeconds: 12,
        uploadState: 'uploaded',
      },
    });

    const token = await login('teacher');
    const res = await request(app.server)
      .post('/feedback')
      .set('Authorization', `Bearer ${token}`)
      .send({
        targetType: 'artifact',
        targetId: artifact.id,
        status: 'ok',
        commentsText: 'Great take',
        markers: [],
      });

    expect(res.status).toBe(201);

    const updatedEntry = await prisma.practiceEntry.findUnique({ where: { id: entry.id } });
    expect(updatedEntry?.status).toBe('reviewed');
  });

  it('rejects artifact creation on submitted entries', async () => {
    const entry = await prisma.practiceEntry.create({
      data: {
        id: 'entry-submitted-no-artifact',
        courseId: 'COURSE_TEST',
        studentId: 'student-1',
        practiceDate: new Date(),
        goalText: 'Already submitted',
        tags: ['tag'],
        status: 'submitted',
      },
    });

    const token = await login('student');
    const res = await request(app.server)
      .post(`/entries/${entry.id}/artifacts`)
      .set('Authorization', `Bearer ${token}`)
      .send({ id: 'artifact-blocked', type: 'audio', durationSeconds: 10, sizeBytes: 1 });

    expect(res.status).toBe(409);
    expect(res.body.error.code).toBe('ENTRY_LOCKED');
  });

  it('rejects artifact creation on reviewed entries', async () => {
    const entry = await prisma.practiceEntry.create({
      data: {
        id: 'entry-reviewed-no-artifact',
        courseId: 'COURSE_TEST',
        studentId: 'student-1',
        practiceDate: new Date(),
        goalText: 'Already reviewed',
        tags: ['tag'],
        status: 'reviewed',
      },
    });

    const token = await login('student');
    const res = await request(app.server)
      .post(`/entries/${entry.id}/artifacts`)
      .set('Authorization', `Bearer ${token}`)
      .send({ id: 'artifact-blocked-2', type: 'audio', durationSeconds: 10, sizeBytes: 1 });

    expect(res.status).toBe(409);
    expect(res.body.error.code).toBe('ENTRY_LOCKED');
  });

  it('allows artifact creation on draft entries', async () => {
    const entry = await prisma.practiceEntry.create({
      data: {
        id: 'entry-draft-artifact-ok',
        courseId: 'COURSE_TEST',
        studentId: 'student-1',
        practiceDate: new Date(),
        goalText: 'Draft entry',
        tags: ['tag'],
        status: 'draft',
      },
    });

    const token = await login('student');
    const res = await request(app.server)
      .post(`/entries/${entry.id}/artifacts`)
      .set('Authorization', `Bearer ${token}`)
      .send({ id: 'artifact-allowed', type: 'audio', durationSeconds: 10, sizeBytes: 1 });

    expect(res.status).toBe(201);
    expect(res.body.id).toBe('artifact-allowed');
  });
});
