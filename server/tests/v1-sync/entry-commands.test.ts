import { describe, expect, it } from 'vitest';
import { prisma } from '../support/testUtils.js';
import {
  createEntryWith,
  enrollFreshMember,
  executeSyncCommands,
  installV1SyncSuite,
  seedArtifact,
  seedEntry,
  syncCommand,
  teachingLessonFields,
  teachingLessonSeed,
} from './support.js';

const execute = executeSyncCommands;
const update = (entityId: string, operationId: string, baseVersion: number, goalText: string) =>
  syncCommand('updateEntry', entityId, operationId, baseVersion, { goalText });
const simple = (kind: string, entityId: string, operationId: string, baseVersion: number) =>
  syncCommand(kind, entityId, operationId, baseVersion);

describe('v1 entry sync commands', () => {
  installV1SyncSuite();

  it('applies createEntry with the contract resource and replays it as a duplicate', async () => {
    const student = await enrollFreshMember('student');
    const first = await execute(student.token, [createEntryWith('entry-a', 'op-create-a')]);
    expect(first.status).toBe(200);
    expect(first.body.results).toHaveLength(1);
    expect(first.body.results[0]).toMatchObject({
      operationId: 'op-create-a',
      entityId: 'entry-a',
      kind: 'createEntry',
      status: 'applied',
      currentVersion: 1,
      resource: {
        id: 'entry-a',
        courseId: 'COURSE_TEST',
        studentId: student.userId,
        version: 1,
        status: 'draft',
        kind: 'practice',
        practiceDate: '2026-07-16T00:00:00.000Z',
        goalText: 'Keep a steady pulse',
        durationSeconds: null,
        tags: [],
        notes: null,
        consentConfirmedAt: null,
        consentScope: null,
        captureProfile: null,
      },
    });
    expect(first.body.results[0].resource.createdAt).toEqual(expect.any(String));
    expect(first.body.results[0].resource.updatedAt).toEqual(expect.any(String));

    const replay = await execute(student.token, [createEntryWith('entry-a', 'op-create-a')]);
    expect(replay.body.results[0]).toMatchObject({ status: 'duplicate', currentVersion: 1 });
    expect(await prisma.practiceEntry.count({ where: { id: 'entry-a' } })).toBe(1);
  });

  it('rejects createEntry for teachers and invalid practice consent metadata', async () => {
    const student = await enrollFreshMember('student');
    const teacher = await enrollFreshMember('teacher');
    const asTeacher = await execute(teacher.token, [createEntryWith('entry-t', 'op-teacher')]);
    expect(asTeacher.status).toBe(200);
    expect(asTeacher.body.results[0]).toMatchObject({ status: 'rejected', code: 'STUDENT_ONLY' });
    expect(asTeacher.body.results[0].resource).toBeUndefined();

    const withConsent = await execute(student.token, [
      createEntryWith('entry-c', 'op-consent', {
        consentConfirmedAt: teachingLessonFields.consentConfirmedAt,
        consentScope: teachingLessonFields.consentScope,
      }),
    ]);
    expect(withConsent.body.results[0]).toMatchObject({
      status: 'rejected',
      code: 'VALIDATION_ERROR',
    });
    expect(
      await prisma.practiceEntry.count({ where: { id: { in: ['entry-t', 'entry-c'] } } })
    ).toBe(0);
  });

  it('applies updateEntry with a version bump and reports stale versions as conflicts', async () => {
    const student = await enrollFreshMember('student');
    await execute(student.token, [createEntryWith('entry-u', 'op-create-u')]);

    const applied = await execute(student.token, [update('entry-u', 'op-update-1', 1, 'Slower')]);
    expect(applied.body.results[0]).toMatchObject({
      status: 'applied',
      currentVersion: 2,
      resource: { id: 'entry-u', version: 2, goalText: 'Slower', status: 'draft' },
    });

    const stale = await execute(student.token, [update('entry-u', 'op-update-stale', 1, 'Late')]);
    expect(stale.body.results[0]).toMatchObject({
      status: 'conflict',
      code: 'VERSION_CONFLICT',
      currentVersion: 2,
      resource: { id: 'entry-u', version: 2, goalText: 'Slower' },
    });
    const row = await prisma.practiceEntry.findUniqueOrThrow({ where: { id: 'entry-u' } });
    expect(row).toMatchObject({ version: 2, goalText: 'Slower' });
  });

  it('locks submitted entries and restricts edits to the owning student', async () => {
    const owner = await enrollFreshMember('student');
    const other = await enrollFreshMember('student');
    await seedEntry('entry-locked', owner.userId, { status: 'submitted', version: 2 });
    await seedEntry('entry-owned', owner.userId);

    const locked = await execute(owner.token, [update('entry-locked', 'op-locked', 2, 'Edit')]);
    expect(locked.body.results[0]).toMatchObject({ status: 'rejected', code: 'ENTRY_LOCKED' });
    const foreign = await execute(other.token, [update('entry-owned', 'op-foreign', 1, 'Edit')]);
    expect(foreign.body.results[0]).toMatchObject({ status: 'rejected', code: 'STUDENT_ONLY' });
    expect(
      (await prisma.practiceEntry.findUniqueOrThrow({ where: { id: 'entry-owned' } })).goalText
    ).toBe('Seeded goal');
  });

  it('requires uploaded artifacts and consent before submitEntry succeeds', async () => {
    const student = await enrollFreshMember('student');
    await seedEntry('entry-s', student.userId);
    await seedEntry('entry-lesson-consent', student.userId, { kind: 'teaching_lesson' });
    await seedEntry('entry-lesson-audio', student.userId, teachingLessonSeed);
    await seedArtifact('audio-only', 'entry-lesson-audio');

    const none = await execute(student.token, [simple('submitEntry', 'entry-s', 'op-s-1', 1)]);
    expect(none.body.results[0]).toMatchObject({
      status: 'rejected',
      code: 'ARTIFACTS_NOT_UPLOADED',
    });
    await seedArtifact('pending-audio', 'entry-s', { uploadState: 'uploading' });
    const pending = await execute(student.token, [simple('submitEntry', 'entry-s', 'op-s-2', 1)]);
    expect(pending.body.results[0]).toMatchObject({
      status: 'rejected',
      code: 'ARTIFACTS_NOT_UPLOADED',
    });
    await prisma.artifact.update({
      where: { id: 'pending-audio' },
      data: { uploadState: 'uploaded' },
    });
    const applied = await execute(student.token, [simple('submitEntry', 'entry-s', 'op-s-3', 1)]);
    expect(applied.body.results[0]).toMatchObject({
      status: 'applied',
      currentVersion: 2,
      resource: { id: 'entry-s', status: 'submitted', version: 2 },
    });

    const noConsent = await execute(student.token, [
      simple('submitEntry', 'entry-lesson-consent', 'op-s-4', 1),
    ]);
    expect(noConsent.body.results[0]).toMatchObject({
      status: 'rejected',
      code: 'CONSENT_REQUIRED',
    });
    const noVideo = await execute(student.token, [
      simple('submitEntry', 'entry-lesson-audio', 'op-s-5', 1),
    ]);
    expect(noVideo.body.results[0]).toMatchObject({
      status: 'rejected',
      code: 'ARTIFACTS_NOT_UPLOADED',
    });
  });

  it('accepts capture markers only on teaching lessons and replaces the full marker set', async () => {
    const student = await enrollFreshMember('student');
    await seedEntry('entry-practice', student.userId);
    await seedEntry('entry-lesson', student.userId, teachingLessonSeed);
    await seedArtifact('lesson-video', 'entry-lesson', { type: 'video' });
    const marker = (id: string, timeSeconds: number, note: string) => ({
      id,
      artifactId: 'lesson-video',
      timeSeconds,
      kind: 'privacy_note',
      note,
    });
    const replace = (operationId: string, baseVersion: number, markers: unknown[]) =>
      syncCommand('replaceCaptureMarkers', 'entry-lesson', operationId, baseVersion, { markers });

    const practice = await execute(student.token, [
      syncCommand('replaceCaptureMarkers', 'entry-practice', 'op-m-0', 1, { markers: [] }),
    ]);
    expect(practice.body.results[0]).toMatchObject({
      status: 'rejected',
      code: 'VALIDATION_ERROR',
    });

    const first = await execute(student.token, [
      replace('op-m-1', 1, [marker('m1', 5, 'one'), marker('m2', 9, 'two')]),
    ]);
    expect(first.body.results[0]).toMatchObject({ status: 'applied', currentVersion: 2 });
    const second = await execute(student.token, [
      replace('op-m-2', 2, [marker('m2', 12, 'moved')]),
    ]);
    expect(second.body.results[0]).toMatchObject({ status: 'applied', currentVersion: 3 });
    const remaining = await prisma.captureMarker.findMany({ where: { entryId: 'entry-lesson' } });
    expect(remaining).toHaveLength(1);
    expect(remaining[0]).toMatchObject({ id: 'm2', timeSeconds: 12, note: 'moved' });
    const cleared = await execute(student.token, [replace('op-m-3', 3, [])]);
    expect(cleared.body.results[0]).toMatchObject({ status: 'applied', currentVersion: 4 });
    expect(await prisma.captureMarker.count({ where: { entryId: 'entry-lesson' } })).toBe(0);
  });

  it('deletes an entry, tombstones its ID, and queues artifact storage for removal', async () => {
    const student = await enrollFreshMember('student');
    await seedEntry('entry-del', student.userId);
    await seedArtifact('del-a1', 'entry-del');
    await seedArtifact('del-a2', 'entry-del', { uploadState: 'uploading' });
    const keys = ['artifacts/final/entry-del/del-a1-key', 'artifacts/final/entry-del/del-a2-key'];

    const deleted = await execute(student.token, [simple('deleteEntry', 'entry-del', 'op-d-1', 1)]);
    expect(deleted.body.results[0]).toMatchObject({ status: 'applied', kind: 'deleteEntry' });
    expect(await prisma.practiceEntry.findUnique({ where: { id: 'entry-del' } })).toBeNull();
    expect(await prisma.artifact.count({ where: { entryId: 'entry-del' } })).toBe(0);
    expect(
      await prisma.deletedEntryTombstone.findUnique({ where: { id: 'entry-del' } })
    ).not.toBeNull();
    const jobs = await prisma.storageDeletionJob.findMany({ where: { entryId: 'entry-del' } });
    expect(jobs.map((job) => job.storageKey).sort()).toEqual(keys);

    const reuse = await execute(student.token, [createEntryWith('entry-del', 'op-d-2')]);
    expect(reuse.body.results[0]).toMatchObject({ status: 'rejected', code: 'ENTRY_DELETED' });
  });

  it('executes batches in request order and continues after a conflict', async () => {
    const student = await enrollFreshMember('student');
    const response = await execute(student.token, [
      createEntryWith('entry-b', 'op-b-1'),
      update('entry-b', 'op-b-2', 1, 'Second'),
      update('entry-b', 'op-b-3', 1, 'Stale'),
      update('entry-b', 'op-b-4', 2, 'Fourth'),
    ]);
    expect(response.status).toBe(200);
    expect(
      response.body.results.map((result: { operationId: string }) => result.operationId)
    ).toEqual(['op-b-1', 'op-b-2', 'op-b-3', 'op-b-4']);
    expect(response.body.results.map((result: { status: string }) => result.status)).toEqual([
      'applied',
      'applied',
      'conflict',
      'applied',
    ]);
    expect(response.body.results[3]).toMatchObject({ currentVersion: 3 });
    expect(
      (await prisma.practiceEntry.findUniqueOrThrow({ where: { id: 'entry-b' } })).goalText
    ).toBe('Fourth');
  });

  it('rejects malformed batches with HTTP 400 before executing any command', async () => {
    const student = await enrollFreshMember('student');
    const commands = (count: number) =>
      Array.from({ length: count }, (_, index) =>
        createEntryWith(`entry-n-${index}`, `op-n-${index}`)
      );
    for (const batch of [commands(0), commands(26)]) {
      const response = await execute(student.token, batch);
      expect(response.status).toBe(400);
      expect(response.body.error.code).toBe('VALIDATION_ERROR');
    }

    const missingBase = await execute(student.token, [
      createEntryWith('entry-n-ok', 'op-n-ok'),
      syncCommand('updateEntry', 'entry-n-ok', 'op-n-bad', undefined, { goalText: 'x' }),
    ]);
    expect(missingBase.status).toBe(400);
    expect(missingBase.body.error.code).toBe('VALIDATION_ERROR');
    expect(await prisma.practiceEntry.count({ where: { studentId: student.userId } })).toBe(0);
  });
});
