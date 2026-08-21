// Exercises compact authenticated helper flows retained from the retired ACL coverage.
import { describe, expect, it } from 'vitest';
import {
  createArtifactSession,
  createTestArtifact,
  createTestEntry,
  createTestFeedback,
  deleteEntry,
  deleteTestUser,
  expectDevSessionIssued,
  getReviewQueue,
  installBasicSuite,
  issueDevSession,
  login,
  postFeedback,
  prisma,
} from './support/testUtils.js';

describe('cleanup regression helper contracts', () => {
  installBasicSuite();

  it('issues a development session and fully removes its test user state', async () => {
    const userId = 'cleanup-session-user';
    const { issue, session } = await issueDevSession('student', { userId });

    expectDevSessionIssued(issue, session);
    await deleteTestUser(userId);

    await expect(prisma.user.findUnique({ where: { id: userId } })).resolves.toBeNull();
    expect(await prisma.refreshToken.count({ where: { userId } })).toBe(0);
  });

  it('exposes submitted work to the course teacher and records direct feedback', async () => {
    const entry = await createTestEntry({
      id: 'cleanup-review-entry',
      practiceDate: new Date(),
      goalText: 'Review this',
      tags: [],
      status: 'submitted',
    });
    const teacher = await login('teacher');

    const queue = await getReviewQueue(teacher);
    const feedback = await postFeedback(teacher, {
      id: 'cleanup-route-feedback',
      targetType: 'entry',
      targetId: entry.id,
      status: 'ok',
      commentsText: 'Clear next step.',
      markers: [],
    });

    expect(queue.body.items.map((item: { id: string }) => item.id)).toContain(entry.id);
    expect(feedback.status).toBe(201);
    await expect(
      prisma.practiceEntry.findUnique({ where: { id: entry.id } })
    ).resolves.toMatchObject({
      status: 'reviewed',
    });
  });

  it('creates upload sessions only for an active owner entry', async () => {
    const entry = await createTestEntry({
      id: 'cleanup-upload-entry',
      practiceDate: new Date(),
      goalText: 'Upload',
      tags: [],
    });
    const token = await login('student');

    const created = await createArtifactSession(token, {
      operationId: 'cleanup-upload-operation',
      entryId: entry.id,
      artifactId: 'cleanup-upload-artifact',
      type: 'audio',
      durationSeconds: 1,
      sizeBytes: 1,
      baseVersion: 1,
    });

    expect(created.status).toBe(200);
    expect(created.body.artifact.storageKey).toMatch(/^artifacts\/staging\//);
  });

  it('cascades direct artifact and feedback fixtures when the owner deletes an entry', async () => {
    const entry = await createTestEntry({
      id: 'cleanup-delete-entry',
      practiceDate: new Date(),
      goalText: 'Delete',
      tags: [],
    });
    const artifact = await createTestArtifact({
      id: 'cleanup-delete-artifact',
      entryId: entry.id,
      type: 'audio',
      durationSeconds: 1,
      uploadState: 'uploaded',
    });
    const feedback = await createTestFeedback({
      id: 'cleanup-delete-feedback',
      targetType: 'artifact',
      targetId: artifact.id,
      entryId: entry.id,
      teacherId: 'teacher-1',
      status: 'ok',
      commentsText: 'Removed with entry.',
    });
    const token = await login('student');

    const deleted = await deleteEntry(token, entry.id);

    expect(deleted.status).toBe(204);
    await expect(prisma.artifact.findUnique({ where: { id: artifact.id } })).resolves.toBeNull();
    await expect(prisma.feedback.findUnique({ where: { id: feedback.id } })).resolves.toBeNull();
  });
});
