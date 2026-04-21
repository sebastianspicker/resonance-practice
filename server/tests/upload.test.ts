import request from 'supertest';
import { beforeAll, afterAll, beforeEach, describe, expect, it } from 'vitest';
import { HeadObjectCommand } from '@aws-sdk/client-s3';
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

describe('media upload flow', () => {
  beforeAll(async () => {
    await setupApp();
  });

  afterAll(async () => {
    await teardownApp();
  });

  beforeEach(async () => {
    await resetDb();
    await seedBasic();
    s3Mock.reset();
  });

  it('presigns and confirms upload', async () => {
    const token = await login('student');

    const entry = await prisma.practiceEntry.create({
      data: {
        id: 'entry-1',
        courseId: 'COURSE_TEST',
        studentId: 'student-1',
        practiceDate: new Date(),
        goalText: 'Practice',
        tags: ['tag'],
        status: 'draft',
      },
    });

    const artifactRes = await request(app.server)
      .post(`/entries/${entry.id}/artifacts`)
      .set('Authorization', `Bearer ${token}`)
      .send({ id: 'artifact-1', type: 'audio', durationSeconds: 60 });

    expect(artifactRes.status).toBe(201);

    const presignRes = await request(app.server)
      .post(`/artifacts/${artifactRes.body.id}/presign`)
      .set('Authorization', `Bearer ${token}`)
      .send();

    expect(presignRes.status).toBe(200);
    expect(typeof presignRes.body.uploadUrl).toBe('string');
    expect(presignRes.body.requiredHeaders?.['Content-Type']).toBe('audio/m4a');

    s3Mock.on(HeadObjectCommand).resolves({ ContentLength: 128 });

    const confirmRes = await request(app.server)
      .post(`/artifacts/${artifactRes.body.id}/confirm`)
      .set('Authorization', `Bearer ${token}`)
      .send();

    expect(confirmRes.status).toBe(200);
    expect(confirmRes.body.uploadState).toBe('uploaded');
  });

  it('denies non-owner student for presign and confirm', async () => {
    const otherStudent = await prisma.user.create({
      data: { id: 'student-2', displayName: 'Other Student', globalRole: 'student' },
    });
    await prisma.membership.create({
      data: { userId: otherStudent.id, courseId: 'COURSE_TEST', roleInCourse: 'student' },
    });

    const ownerToken = await login('student');
    const otherToken = await getAccessToken('student', { userId: 'student-2' });

    const entry = await prisma.practiceEntry.create({
      data: {
        id: 'entry-2',
        courseId: 'COURSE_TEST',
        studentId: 'student-1',
        practiceDate: new Date(),
        goalText: 'Practice',
        tags: ['tag'],
        status: 'draft',
      },
    });

    const artifactRes = await request(app.server)
      .post(`/entries/${entry.id}/artifacts`)
      .set('Authorization', `Bearer ${ownerToken}`)
      .send({ id: 'artifact-2', type: 'audio', durationSeconds: 30 });
    expect(artifactRes.status).toBe(201);

    const presignRes = await request(app.server)
      .post(`/artifacts/${artifactRes.body.id}/presign`)
      .set('Authorization', `Bearer ${otherToken}`)
      .send();
    expect(presignRes.status).toBe(403);

    const confirmRes = await request(app.server)
      .post(`/artifacts/${artifactRes.body.id}/confirm`)
      .set('Authorization', `Bearer ${otherToken}`)
      .send();
    expect(confirmRes.status).toBe(403);
  });

  it('denies teacher for presign and confirm', async () => {
    const studentToken = await login('student');
    const teacherToken = await login('teacher');

    const entry = await prisma.practiceEntry.create({
      data: {
        id: 'entry-3',
        courseId: 'COURSE_TEST',
        studentId: 'student-1',
        practiceDate: new Date(),
        goalText: 'Practice',
        tags: ['tag'],
        status: 'draft',
      },
    });

    const artifactRes = await request(app.server)
      .post(`/entries/${entry.id}/artifacts`)
      .set('Authorization', `Bearer ${studentToken}`)
      .send({ id: 'artifact-3', type: 'audio', durationSeconds: 30 });
    expect(artifactRes.status).toBe(201);

    const presignRes = await request(app.server)
      .post(`/artifacts/${artifactRes.body.id}/presign`)
      .set('Authorization', `Bearer ${teacherToken}`)
      .send();
    expect(presignRes.status).toBe(403);

    const confirmRes = await request(app.server)
      .post(`/artifacts/${artifactRes.body.id}/confirm`)
      .set('Authorization', `Bearer ${teacherToken}`)
      .send();
    expect(confirmRes.status).toBe(403);
  });
});
