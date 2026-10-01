import request from 'supertest';
import { describe, expect, it } from 'vitest';
import { app, prisma } from '../support/testUtils.js';
import {
  enrollFreshMember,
  executeSyncCommands,
  installV1SyncSuite,
  seedArtifact,
  seedEntry,
  syncCommand,
} from './support.js';

const execute = executeSyncCommands;
const feedback = (
  entityId: string,
  operationId: string,
  baseVersion: number,
  payload: Record<string, unknown>
) =>
  syncCommand('createFeedback', entityId, operationId, baseVersion, {
    targetType: 'entry',
    targetId: 'entry-f',
    status: 'next_goal',
    commentsText: 'Keep the pulse steady',
    markers: [{ id: 'fb-marker-1', timeSeconds: 4, text: 'Rushing here' }],
    ...payload,
  });

describe('v1 feedback sync commands', () => {
  installV1SyncSuite();

  async function arrange(status: 'draft' | 'submitted' = 'submitted') {
    const student = await enrollFreshMember('student');
    const teacher = await enrollFreshMember('teacher');
    await seedEntry('entry-f', student.userId, { status, version: status === 'draft' ? 1 : 2 });
    await seedArtifact('artifact-f', 'entry-f');
    return { student, teacher };
  }

  it('lets a teacher review a submitted entry and exposes the feedback to the student', async () => {
    const { student, teacher } = await arrange();
    const result = await execute(teacher.token, [feedback('fb-1', 'op-fb-1', 2, {})]);
    expect(result.status).toBe(200);
    expect(result.body.results[0]).toMatchObject({
      operationId: 'op-fb-1',
      entityId: 'fb-1',
      kind: 'createFeedback',
      status: 'applied',
      currentVersion: 3,
      resource: { id: 'entry-f', status: 'reviewed', version: 3, studentId: student.userId },
    });

    const read = await request(app.server)
      .get('/api/v1/entries/entry-f/feedback')
      .set('authorization', `Bearer ${student.token}`);
    expect(read.status).toBe(200);
    expect(read.body.nextCursor).toBeNull();
    expect(read.body.items).toHaveLength(1);
    expect(read.body.items[0]).toMatchObject({
      id: 'fb-1',
      targetType: 'entry',
      targetId: 'entry-f',
      teacherName: expect.stringContaining('Fresh teacher'),
      status: 'next_goal',
      commentsText: 'Keep the pulse steady',
      markers: [{ id: 'fb-marker-1', timeSeconds: 4, text: 'Rushing here' }],
    });
    expect(read.body.items[0]).not.toHaveProperty('teacherId');

    const replay = await execute(teacher.token, [feedback('fb-1', 'op-fb-1', 2, {})]);
    expect(replay.body.results[0]).toMatchObject({ status: 'duplicate', currentVersion: 3 });
  });

  it('accepts artifact-targeted feedback for an artifact of the submitted entry', async () => {
    const { teacher } = await arrange();
    const result = await execute(teacher.token, [
      feedback('fb-artifact', 'op-fb-art', 2, {
        targetType: 'artifact',
        targetId: 'artifact-f',
        markers: [],
      }),
    ]);
    expect(result.body.results[0]).toMatchObject({
      status: 'applied',
      resource: { id: 'entry-f', status: 'reviewed' },
    });
    expect(await prisma.feedback.findUniqueOrThrow({ where: { id: 'fb-artifact' } })).toMatchObject(
      {
        targetType: 'artifact',
        targetId: 'artifact-f',
        entryId: 'entry-f',
      }
    );
  });

  it('rejects feedback from students and for entries that are still drafts', async () => {
    const { student, teacher } = await arrange();
    const byStudent = await execute(student.token, [feedback('fb-s', 'op-fb-s', 2, {})]);
    expect(byStudent.body.results[0]).toMatchObject({ status: 'rejected', code: 'TEACHER_ONLY' });
    expect(await prisma.feedback.count()).toBe(0);

    await prisma.practiceEntry.update({
      where: { id: 'entry-f' },
      data: { status: 'draft', version: 1 },
    });
    const onDraft = await execute(teacher.token, [feedback('fb-d', 'op-fb-d', 1, {})]);
    expect(onDraft.body.results[0]).toMatchObject({
      status: 'rejected',
      code: 'ENTRY_NOT_SUBMITTED',
    });
    expect(await prisma.feedback.count()).toBe(0);
  });

  it('rejects unknown artifact targets and reports stale versions as conflicts', async () => {
    const { teacher } = await arrange();
    const unknown = await execute(teacher.token, [
      feedback('fb-u', 'op-fb-u', 2, { targetType: 'artifact', targetId: 'missing-artifact' }),
    ]);
    expect(unknown.body.results[0]).toMatchObject({
      status: 'rejected',
      code: 'ARTIFACT_NOT_FOUND',
    });

    const stale = await execute(teacher.token, [feedback('fb-v', 'op-fb-v', 1, {})]);
    expect(stale.body.results[0]).toMatchObject({
      status: 'conflict',
      code: 'VERSION_CONFLICT',
      currentVersion: 2,
      resource: { id: 'entry-f', version: 2, status: 'submitted' },
    });
    expect(await prisma.feedback.count()).toBe(0);
  });

  it('rejects a feedback ID reused with different content under a new operation ID', async () => {
    const { teacher } = await arrange();
    await execute(teacher.token, [feedback('fb-id', 'op-fb-id-1', 2, {})]);
    const reused = await execute(teacher.token, [
      feedback('fb-id', 'op-fb-id-2', 3, { commentsText: 'Different comments' }),
    ]);
    expect(reused.body.results[0]).toMatchObject({ status: 'rejected', code: 'ID_CONFLICT' });
    expect((await prisma.feedback.findUniqueOrThrow({ where: { id: 'fb-id' } })).commentsText).toBe(
      'Keep the pulse steady'
    );
  });
});
