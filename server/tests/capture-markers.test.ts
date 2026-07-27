// Verifies teaching-lesson marker ownership, replacement, and video-only constraints.
import request from 'supertest';
import { describe, expect, it } from 'vitest';
import { app, getReviewQueue, installBasicSuite, login, prisma } from './support/testUtils.js';

async function seedTeachingLesson(status: 'draft' | 'submitted' | 'reviewed' = 'draft') {
  await prisma.practiceEntry.create({
    data: {
      id: 'entry-teaching-capture',
      courseId: 'COURSE_TEST',
      studentId: 'student-1',
      kind: 'teaching_lesson',
      practiceDate: new Date('2026-04-29T10:00:00.000Z'),
      goalText: 'Teach ensemble cueing',
      tags: ['lehramt'],
      status,
      consentConfirmedAt: new Date('2026-04-29T09:00:00.000Z'),
      consentScope: 'private_course_review',
      captureProfile: 'teacher_learner',
    },
  });
  await prisma.artifact.create({
    data: {
      id: 'artifact-lesson-video',
      entryId: 'entry-teaching-capture',
      type: 'video',
      durationSeconds: 180,
      uploadState: 'uploaded',
    },
  });
}

describe('capture marker sync', () => {
  installBasicSuite();

  it('upserts capture markers for the owning student and returns them by time', async () => {
    await seedTeachingLesson();
    const token = await login('student');

    const create = await request(app.server)
      .put('/entries/entry-teaching-capture/capture-markers')
      .set('Authorization', `Bearer ${token}`)
      .send({
        markers: [
          {
            id: 'capture-marker-2',
            artifactId: 'artifact-lesson-video',
            timeSeconds: 40,
            kind: 'moment_student_response',
            note: 'Student echoes the rhythm.',
          },
          {
            id: 'capture-marker-1',
            artifactId: 'artifact-lesson-video',
            timeSeconds: 5,
            kind: 'phase_setup',
            note: 'Camera and group setup.',
          },
        ],
      });

    expect(create.status).toBe(200);
    expect(create.body.map((marker: { id: string }) => marker.id)).toEqual([
      'capture-marker-1',
      'capture-marker-2',
    ]);

    const update = await request(app.server)
      .put('/entries/entry-teaching-capture/capture-markers')
      .set('Authorization', `Bearer ${token}`)
      .send({
        markers: [
          {
            id: 'capture-marker-2',
            artifactId: 'artifact-lesson-video',
            timeSeconds: 41,
            kind: 'moment_student_response',
            note: 'Updated note.',
          },
        ],
      });

    expect(update.status).toBe(200);
    expect(update.body.map((marker: { id: string }) => marker.id)).toEqual(['capture-marker-2']);
    const updated = update.body.find((marker: { id: string }) => marker.id === 'capture-marker-2');
    expect(updated.timeSeconds).toBe(41);
    expect(updated.note).toBe('Updated note.');
  });

  it('replaces the marker set when syncing an empty marker list', async () => {
    await seedTeachingLesson();
    await prisma.captureMarker.create({
      data: {
        id: 'capture-marker-cleared',
        entryId: 'entry-teaching-capture',
        artifactId: 'artifact-lesson-video',
        studentId: 'student-1',
        timeSeconds: 12,
        kind: 'phase_modeling',
      },
    });
    const token = await login('student');

    const res = await request(app.server)
      .put('/entries/entry-teaching-capture/capture-markers')
      .set('Authorization', `Bearer ${token}`)
      .send({ markers: [] });

    expect(res.status).toBe(200);
    expect(res.body).toEqual([]);
    await expect(
      prisma.captureMarker.count({ where: { entryId: 'entry-teaching-capture' } })
    ).resolves.toBe(0);
  });

  it('includes capture markers on entry detail reads', async () => {
    await seedTeachingLesson();
    await prisma.captureMarker.create({
      data: {
        id: 'capture-marker-detail',
        entryId: 'entry-teaching-capture',
        artifactId: 'artifact-lesson-video',
        studentId: 'student-1',
        timeSeconds: 12,
        kind: 'moment_question',
        note: 'Prompt to alto group.',
      },
    });
    const token = await login('teacher');

    const res = await request(app.server)
      .get('/entries/entry-teaching-capture')
      .set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(200);
    expect(res.body.captureProfile).toBe('teacher_learner');
    expect(res.body.captureMarkers).toHaveLength(1);
    expect(res.body.captureMarkers[0].kind).toBe('moment_question');
  });

  it('adds captureMarkerCount to the teacher review queue', async () => {
    await seedTeachingLesson('submitted');
    await prisma.captureMarker.create({
      data: {
        id: 'capture-marker-count',
        entryId: 'entry-teaching-capture',
        artifactId: 'artifact-lesson-video',
        studentId: 'student-1',
        timeSeconds: 20,
        kind: 'phase_modeling',
      },
    });
    const token = await login('teacher');

    const res = await getReviewQueue(token);

    expect(res.status).toBe(200);
    expect(res.body.items[0].captureProfile).toBe('teacher_learner');
    expect(res.body.items[0].captureMarkerCount).toBe(1);
  });

  it('rejects capture markers for practice entries', async () => {
    await prisma.practiceEntry.create({
      data: {
        id: 'entry-practice-capture',
        courseId: 'COURSE_TEST',
        studentId: 'student-1',
        practiceDate: new Date(),
        goalText: 'Practice entry',
        tags: [],
      },
    });
    await prisma.artifact.create({
      data: {
        id: 'artifact-practice-video',
        entryId: 'entry-practice-capture',
        type: 'video',
        durationSeconds: 30,
      },
    });
    const token = await login('student');

    const res = await request(app.server)
      .put('/entries/entry-practice-capture/capture-markers')
      .set('Authorization', `Bearer ${token}`)
      .send({
        markers: [
          {
            id: 'capture-marker-practice',
            artifactId: 'artifact-practice-video',
            timeSeconds: 1,
            kind: 'phase_setup',
          },
        ],
      });

    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe('VALIDATION_ERROR');
  });

  it('rejects teacher writes and reviewed-entry writes', async () => {
    await seedTeachingLesson('reviewed');
    const teacherToken = await login('teacher');
    const studentToken = await login('student');

    const teacherRes = await request(app.server)
      .put('/entries/entry-teaching-capture/capture-markers')
      .set('Authorization', `Bearer ${teacherToken}`)
      .send({ markers: [] });
    expect(teacherRes.status).toBe(403);
    expect(teacherRes.body.error.code).toBe('STUDENT_ONLY');

    const reviewedRes = await request(app.server)
      .put('/entries/entry-teaching-capture/capture-markers')
      .set('Authorization', `Bearer ${studentToken}`)
      .send({ markers: [] });
    expect(reviewedRes.status).toBe(409);
    expect(reviewedRes.body.error.code).toBe('ENTRY_LOCKED');
  });

  it('rejects markers for non-video artifacts', async () => {
    await seedTeachingLesson();
    await prisma.artifact.create({
      data: {
        id: 'artifact-lesson-audio',
        entryId: 'entry-teaching-capture',
        type: 'audio',
        durationSeconds: 30,
      },
    });
    const token = await login('student');

    const res = await request(app.server)
      .put('/entries/entry-teaching-capture/capture-markers')
      .set('Authorization', `Bearer ${token}`)
      .send({
        markers: [
          {
            id: 'capture-marker-audio',
            artifactId: 'artifact-lesson-audio',
            timeSeconds: 1,
            kind: 'phase_setup',
          },
        ],
      });

    expect(res.status).toBe(404);
    expect(res.body.error.code).toBe('ARTIFACT_NOT_FOUND');
  });
});
