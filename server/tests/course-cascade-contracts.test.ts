// Course membership is the isolation boundary; deleting an owned entry removes its private graph atomically.
import request from 'supertest';
import { describe, expect, it } from 'vitest';
import { app, installBasicSuite, login, prisma } from './support/testUtils.js';

describe('course visibility and entry cascade', () => {
  installBasicSuite();

  it('isolates student records while exposing submitted work only to same-course teachers', async () => {
    await prisma.user.create({
      data: { id: 'student-2', displayName: 'Other student', globalRole: 'student' },
    });
    await prisma.membership.create({
      data: { userId: 'student-2', courseId: 'COURSE_TEST', roleInCourse: 'student' },
    });
    await prisma.practiceEntry.create({
      data: {
        id: 'other-student-entry',
        courseId: 'COURSE_TEST',
        studentId: 'student-2',
        practiceDate: new Date(),
        goalText: 'Private draft',
        tags: [],
        status: 'draft',
      },
    });
    await prisma.practiceEntry.create({
      data: {
        id: 'submitted-entry',
        courseId: 'COURSE_TEST',
        studentId: 'student-2',
        practiceDate: new Date(),
        goalText: 'Reviewable',
        tags: [],
        status: 'submitted',
      },
    });

    const student = await login('student');
    const teacher = await login('teacher');
    const studentEntries = await request(app.server)
      .get('/api/v1/courses/COURSE_TEST/entries')
      .set('authorization', `Bearer ${student}`);
    const teacherEntries = await request(app.server)
      .get('/api/v1/courses/COURSE_TEST/entries')
      .set('authorization', `Bearer ${teacher}`);

    expect(studentEntries.body.items.map((entry: { id: string }) => entry.id)).not.toContain(
      'other-student-entry'
    );
    expect(teacherEntries.body.items.map((entry: { id: string }) => entry.id)).toEqual([
      'submitted-entry',
    ]);
  });

  it('cascades artifacts and both feedback targets, then records a deletion tombstone', async () => {
    const entry = await prisma.practiceEntry.create({
      data: {
        id: 'cascade-entry',
        courseId: 'COURSE_TEST',
        studentId: 'student-1',
        practiceDate: new Date(),
        goalText: 'Delete',
        tags: [],
        status: 'submitted',
      },
    });
    const artifact = await prisma.artifact.create({
      data: {
        id: 'cascade-artifact',
        entryId: entry.id,
        type: 'audio',
        durationSeconds: 1,
        uploadState: 'uploaded',
        storageKey: 'artifacts/final/cascade-entry/cascade-artifact',
      },
    });
    await prisma.feedback.createMany({
      data: [
        {
          id: 'cascade-entry-feedback',
          targetType: 'entry',
          targetId: entry.id,
          entryId: entry.id,
          teacherId: 'teacher-1',
          status: 'ok',
          commentsText: 'entry',
        },
        {
          id: 'cascade-artifact-feedback',
          targetType: 'artifact',
          targetId: artifact.id,
          entryId: entry.id,
          teacherId: 'teacher-1',
          status: 'ok',
          commentsText: 'artifact',
        },
      ],
    });

    const student = await login('student');
    const deleted = await request(app.server)
      .delete(`/entries/${entry.id}`)
      .set('authorization', `Bearer ${student}`);

    expect(deleted.status).toBe(204);
    await expect(prisma.practiceEntry.findUnique({ where: { id: entry.id } })).resolves.toBeNull();
    expect(await prisma.artifact.count({ where: { entryId: entry.id } })).toBe(0);
    expect(await prisma.feedback.count({ where: { entryId: entry.id } })).toBe(0);
    await expect(
      prisma.deletedEntryTombstone.findUnique({ where: { id: entry.id } })
    ).resolves.toMatchObject({ id: entry.id });
    await expect(
      prisma.storageDeletionJob.findUnique({ where: { storageKey: artifact.storageKey! } })
    ).resolves.toMatchObject({ entryId: entry.id });
  });
});
