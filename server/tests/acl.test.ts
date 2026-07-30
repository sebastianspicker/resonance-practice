// Verifies course-role access control, draft privacy, and complete entry deletion.
import request from 'supertest';
import { describe, expect, it } from 'vitest';
import { DeleteObjectCommand } from '@aws-sdk/client-s3';
import {
  app,
  createArtifactSession,
  createTestArtifact,
  createTestEntry,
  createTestFeedback,
  deleteEntry,
  getAccessToken,
  getReviewQueue,
  installBasicSuite,
  login,
  postFeedback,
  prisma,
  s3Mock,
} from './support/testUtils.js';

async function createSubmittedEntry(id: string) {
  return createTestEntry({
    id,
    practiceDate: new Date(),
    goalText: 'Retry target',
    tags: ['tag'],
    status: 'submitted',
  });
}

async function createReviewQueueEntry(id: string, practiceDate: Date, createdAt?: Date) {
  return createTestEntry({
    id,
    practiceDate,
    createdAt,
    goalText: 'Review queue entry',
    tags: ['tag'],
    status: 'submitted',
  });
}

async function submitFeedback(token: string, body: Record<string, unknown>) {
  return postFeedback(token, body);
}

function artifactSessionBody(operationId: string, entryId: string, artifactId: string) {
  return {
    operationId,
    entryId,
    artifactId,
    type: 'audio',
    durationSeconds: 10,
    sizeBytes: 1,
    baseVersion: 1,
  };
}

function idempotentFeedbackBody(id: string, targetId: string) {
  return {
    id,
    targetType: 'entry',
    targetId,
    status: 'ok',
    commentsText: 'Stable feedback',
    markers: [{ timeSeconds: 3, text: 'steady' }],
  };
}

async function expectEntryReviewed(entryId: string) {
  const updatedEntry = await prisma.practiceEntry.findUnique({ where: { id: entryId } });
  expect(updatedEntry?.status).toBe('reviewed');
}

function expectNoS3Deletion() {
  expect(s3Mock.commandCalls(DeleteObjectCommand)).toHaveLength(0);
}

async function expectDeletedEntryAndArtifacts(
  entryId: string,
  artifactIds: string[],
  storageKeys: string[]
) {
  const [entryAfter, tombstone, deletionJobs, artifactsAfter, artifactFeedbackAfter] =
    await Promise.all([
      prisma.practiceEntry.findUnique({ where: { id: entryId } }),
      prisma.deletedEntryTombstone.findUnique({ where: { id: entryId } }),
      prisma.storageDeletionJob.findMany({ where: { entryId } }),
      Promise.all(artifactIds.map((id) => prisma.artifact.findUnique({ where: { id } }))),
      prisma.feedback.findMany({ where: { targetId: { in: artifactIds } } }),
    ]);

  expect(entryAfter).toBeNull();
  expect(tombstone).toMatchObject({ id: entryId });
  expect(deletionJobs.map((job) => job.storageKey).sort()).toEqual(storageKeys.sort());
  expect(artifactsAfter).toEqual(artifactIds.map(() => null));
  expect(artifactFeedbackAfter).toHaveLength(0);
}

describe('acl', () => {
  installBasicSuite();

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
    await createSubmittedEntry('entry-submitted');

    const token = await login('teacher');
    const res = await getReviewQueue(token);

    expect(res.status).toBe(200);
    expect(res.body.items.length).toBe(1);
    expect(res.body.nextCursor).toBeNull();
  });

  it('never exposes draft entries or their artifacts to teachers', async () => {
    await prisma.practiceEntry.create({
      data: {
        id: 'entry-teacher-hidden-draft',
        courseId: 'COURSE_TEST',
        studentId: 'student-1',
        practiceDate: new Date(),
        goalText: 'Private draft',
        tags: [],
        status: 'draft',
      },
    });
    await prisma.artifact.create({
      data: {
        id: 'artifact-teacher-hidden-draft',
        entryId: 'entry-teacher-hidden-draft',
        type: 'audio',
        durationSeconds: 1,
        uploadState: 'uploaded',
        storageKey: 'private/draft',
      },
    });
    const token = await login('teacher');
    const protectedGetPaths = [
      '/courses/COURSE_TEST/entries?status=draft',
      '/api/v1/courses/COURSE_TEST/entries?status=draft',
      '/entries/entry-teacher-hidden-draft',
      '/api/v1/entries/entry-teacher-hidden-draft',
      '/artifacts/artifact-teacher-hidden-draft/download',
    ];

    for (const path of protectedGetPaths) {
      const response = await request(app.server).get(path).set('Authorization', `Bearer ${token}`);
      expect(response.status).toBe(403);
      expect(response.body.error.code).toBe('ENTRY_ACCESS_DENIED');
    }
    const downloadResponse = await request(app.server)
      .post('/api/v1/artifacts/artifact-teacher-hidden-draft/download-session')
      .set('Authorization', `Bearer ${token}`);
    expect(downloadResponse.status).toBe(403);
    expect(downloadResponse.body.error.code).toBe('ENTRY_ACCESS_DENIED');
  });

  it('returns review queue sorted by practiceDate desc then createdAt desc', async () => {
    await createReviewQueueEntry(
      'entry-old-practice',
      new Date('2025-01-01T10:00:00.000Z'),
      new Date('2025-01-01T09:00:00.000Z')
    );
    await createReviewQueueEntry(
      'entry-new-practice',
      new Date('2025-01-02T10:00:00.000Z'),
      new Date('2025-01-01T08:00:00.000Z')
    );
    await createReviewQueueEntry(
      'entry-same-practice-newer-created',
      new Date('2025-01-02T10:00:00.000Z'),
      new Date('2025-01-02T11:00:00.000Z')
    );

    const token = await login('teacher');
    const res = await getReviewQueue(token);

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

    const entry = await createTestEntry({
      id: 'entry-hard-delete',
      practiceDate: new Date(),
      goalText: 'Delete me',
      tags: ['tag'],
      status: 'draft',
    });

    const artifact = await createTestArtifact({
      id: 'artifact-hard-delete',
      entryId: entry.id,
      type: 'audio',
      durationSeconds: 10,
      uploadState: 'uploaded',
      storageKey: 'artifacts/entry-hard-delete/artifact-hard-delete',
    });

    await createTestFeedback({
      id: 'fb_entry_1',
      targetType: 'entry',
      targetId: entry.id,
      teacherId: 'teacher-1',
      status: 'ok',
      commentsText: 'Good job',
      markers: {
        create: [{ id: 'mk_entry_1', timeSeconds: 1, text: 'nice' }],
      },
    });

    await createTestFeedback({
      id: 'fb_artifact_1',
      targetType: 'artifact',
      targetId: artifact.id,
      teacherId: 'teacher-1',
      status: 'ok',
      commentsText: 'Nice sound',
      markers: {
        create: [{ id: 'mk_artifact_1', timeSeconds: 2, text: 'tone' }],
      },
    });

    const token = await login('student');
    const res = await deleteEntry(token, entry.id);

    expect(res.status).toBe(204);
    expectNoS3Deletion();

    const feedbackAfter = await prisma.feedback.findMany({ where: { targetId: entry.id } });
    const markerAfter = await prisma.marker.findUnique({ where: { id: 'mk_entry_1' } });
    await expectDeletedEntryAndArtifacts(entry.id, [artifact.id], [artifact.storageKey]);
    expect(feedbackAfter.length).toBe(0);
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

    const entry = await createTestEntry({
      id: 'entry-multi-artifact',
      practiceDate: new Date(),
      goalText: 'Multi artifact delete test',
      tags: [],
      status: 'draft',
    });

    const artifact1 = await createTestArtifact({
      id: 'artifact-multi-1',
      entryId: entry.id,
      type: 'audio',
      durationSeconds: 10,
      uploadState: 'uploaded',
      storageKey: 'artifacts/entry-multi-artifact/artifact-multi-1',
    });

    const artifact2 = await createTestArtifact({
      id: 'artifact-multi-2',
      entryId: entry.id,
      type: 'video',
      durationSeconds: 20,
      uploadState: 'uploaded',
      storageKey: 'artifacts/entry-multi-artifact/artifact-multi-2',
    });

    // Add feedback on each artifact
    await createTestFeedback({
      id: 'fb_multi_1',
      targetType: 'artifact',
      targetId: artifact1.id,
      teacherId: 'teacher-1',
      status: 'ok',
      commentsText: 'Feedback on artifact 1',
    });

    await createTestFeedback({
      id: 'fb_multi_2',
      targetType: 'artifact',
      targetId: artifact2.id,
      teacherId: 'teacher-1',
      status: 'needs_revision',
      commentsText: 'Feedback on artifact 2',
    });

    const token = await login('student');
    const res = await deleteEntry(token, entry.id);

    expect(res.status).toBe(204);

    // Object deletion is durable and asynchronous, not part of the request.
    expectNoS3Deletion();

    await expectDeletedEntryAndArtifacts(
      entry.id,
      [artifact1.id, artifact2.id],
      [artifact1.storageKey, artifact2.storageKey]
    );
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
    const entry = await createTestEntry({
      id: 'entry-bad-artifact',
      practiceDate: new Date(),
      goalText: 'Invalid artifact',
      tags: ['tag'],
      status: 'draft',
    });

    const token = await login('student');
    const res = await createArtifactSession(token, {
      operationId: 'bad-artifact-operation',
      entryId: entry.id,
      artifactId: 'artifact-bad',
      type: 'image',
      durationSeconds: 5,
      sizeBytes: 1,
      baseVersion: 1,
    });

    expect(res.status).toBe(400);
  });

  it('rejects invalid feedback status', async () => {
    const entry = await createTestEntry({
      id: 'entry-bad-feedback',
      practiceDate: new Date(),
      goalText: 'Feedback target',
      tags: ['tag'],
      status: 'submitted',
    });

    const token = await login('teacher');
    const res = await postFeedback(token, {
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
    const res = await postFeedback(token, {
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
    const res = await postFeedback(token, {
      targetType: 'artifact',
      targetId: 'non-existent-artifact-id',
      status: 'ok',
      commentsText: 'This should fail',
      markers: [],
    });

    expect(res.status).toBe(404);
  });

  it('marks entry as reviewed when teacher posts feedback directly on entry', async () => {
    const entry = await createTestEntry({
      id: 'entry-review-status',
      practiceDate: new Date(),
      goalText: 'Review target',
      tags: ['tag'],
      status: 'submitted',
    });

    const token = await login('teacher');
    const res = await postFeedback(token, {
      targetType: 'entry',
      targetId: entry.id,
      status: 'ok',
      commentsText: 'Looks good',
      markers: [],
    });

    expect(res.status).toBe(201);

    await expectEntryReviewed(entry.id);
  });

  it('treats repeated client feedback ids as idempotent retries', async () => {
    const entry = await createSubmittedEntry('entry-idempotent-feedback');

    const token = await login('teacher');
    const body = idempotentFeedbackBody('feedback_retry_1', entry.id);

    const first = await submitFeedback(token, body);
    const second = await submitFeedback(token, body);

    expect(first.status).toBe(201);
    expect(second.status).toBe(200);
    expect(second.body.id).toBe('feedback_retry_1');

    const feedbackRows = await prisma.feedback.findMany({ where: { id: 'feedback_retry_1' } });
    const markerRows = await prisma.marker.findMany({ where: { feedbackId: 'feedback_retry_1' } });
    expect(feedbackRows).toHaveLength(1);
    expect(markerRows).toHaveLength(1);
  });

  it.each([
    ['status', { status: 'needs_revision' }],
    ['comments', { commentsText: 'Changed feedback' }],
    ['markers', { markers: [{ timeSeconds: 4, text: 'steady' }] }],
  ])('rejects reused client feedback ids when %s change', async (_field, change) => {
    const entry = await createSubmittedEntry(`entry-feedback-${_field}-conflict`);
    const token = await login('teacher');
    const body = idempotentFeedbackBody(`feedback_retry_${_field}_conflict`, entry.id);

    const first = await submitFeedback(token, body);
    const second = await submitFeedback(token, { ...body, ...change });

    expect(first.status).toBe(201);
    expect(second.status).toBe(409);
    expect(second.body.error?.code).toBe('ID_CONFLICT');
  });

  it('marks parent entry as reviewed when teacher posts feedback on artifact', async () => {
    const entry = await createTestEntry({
      id: 'entry-artifact-review-status',
      practiceDate: new Date(),
      goalText: 'Artifact review target',
      tags: ['tag'],
      status: 'submitted',
    });
    const artifact = await createTestArtifact({
      id: 'artifact-review-status',
      entryId: entry.id,
      type: 'audio',
      durationSeconds: 12,
      uploadState: 'uploaded',
    });

    const token = await login('teacher');
    const res = await postFeedback(token, {
      targetType: 'artifact',
      targetId: artifact.id,
      status: 'ok',
      commentsText: 'Great take',
      markers: [],
    });

    expect(res.status).toBe(201);

    await expectEntryReviewed(entry.id);
  });

  it('rejects artifact creation on submitted entries', async () => {
    const entry = await createTestEntry({
      id: 'entry-submitted-no-artifact',
      practiceDate: new Date(),
      goalText: 'Already submitted',
      tags: ['tag'],
      status: 'submitted',
    });

    const token = await login('student');
    const res = await createArtifactSession(
      token,
      artifactSessionBody('submitted-artifact-operation', entry.id, 'artifact-blocked')
    );

    expect(res.status).toBe(409);
    expect(res.body.error.code).toBe('ENTRY_LOCKED');
  });

  it('rejects artifact creation on reviewed entries', async () => {
    const entry = await createTestEntry({
      id: 'entry-reviewed-no-artifact',
      practiceDate: new Date(),
      goalText: 'Already reviewed',
      tags: ['tag'],
      status: 'reviewed',
    });

    const token = await login('student');
    const res = await createArtifactSession(
      token,
      artifactSessionBody('reviewed-artifact-operation', entry.id, 'artifact-blocked-2')
    );

    expect(res.status).toBe(409);
    expect(res.body.error.code).toBe('ENTRY_LOCKED');
  });

  it('allows artifact creation on draft entries', async () => {
    const entry = await createTestEntry({
      id: 'entry-draft-artifact-ok',
      practiceDate: new Date(),
      goalText: 'Draft entry',
      tags: ['tag'],
      status: 'draft',
    });

    const token = await login('student');
    const res = await createArtifactSession(token, {
      operationId: 'draft-artifact-operation',
      entryId: entry.id,
      artifactId: 'artifact-allowed',
      type: 'audio',
      durationSeconds: 10,
      sizeBytes: 1,
      baseVersion: 1,
    });

    expect(res.status).toBe(200);
    expect(res.body.artifact.id).toBe('artifact-allowed');
  });
});
