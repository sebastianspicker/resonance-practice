import request from 'supertest';
import { beforeAll, afterAll, beforeEach, describe, expect, it } from 'vitest';
import { GetObjectCommand, HeadObjectCommand } from '@aws-sdk/client-s3';
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
      .send({ id: 'artifact-1', type: 'audio', durationSeconds: 60, sizeBytes: 128 });

    expect(artifactRes.status).toBe(201);

    const presignRes = await request(app.server)
      .post(`/artifacts/${artifactRes.body.id}/presign`)
      .set('Authorization', `Bearer ${token}`)
      .send();

    expect(presignRes.status).toBe(200);
    expect(typeof presignRes.body.uploadUrl).toBe('string');
    expect(presignRes.body.requiredHeaders?.['Content-Type']).toBe('audio/m4a');
    expect(presignRes.body.requiredHeaders?.['Content-Length']).toBe('128');

    s3Mock.on(HeadObjectCommand).resolves({ ContentLength: 128 });

    const confirmRes = await request(app.server)
      .post(`/artifacts/${artifactRes.body.id}/confirm`)
      .set('Authorization', `Bearer ${token}`)
      .send();

    expect(confirmRes.status).toBe(200);
    expect(confirmRes.body.uploadState).toBe('uploaded');
  });

  it('allows presign retry for an interrupted upload and preserves the storage key', async () => {
    const token = await login('student');

    const entry = await prisma.practiceEntry.create({
      data: {
        id: 'entry-retry',
        courseId: 'COURSE_TEST',
        studentId: 'student-1',
        practiceDate: new Date(),
        goalText: 'Retry upload',
        tags: ['tag'],
        status: 'draft',
      },
    });

    const artifactRes = await request(app.server)
      .post(`/entries/${entry.id}/artifacts`)
      .set('Authorization', `Bearer ${token}`)
      .send({ id: 'artifact-retry', type: 'audio', durationSeconds: 60, sizeBytes: 128 });

    expect(artifactRes.status).toBe(201);

    const firstPresign = await request(app.server)
      .post(`/artifacts/${artifactRes.body.id}/presign`)
      .set('Authorization', `Bearer ${token}`)
      .send();

    expect(firstPresign.status).toBe(200);
    expect(firstPresign.body.storageKey).toMatch(
      new RegExp(`^artifacts/${entry.id}/${artifactRes.body.id}-`)
    );

    const afterFirstPresign = await prisma.artifact.findUniqueOrThrow({
      where: { id: artifactRes.body.id },
    });
    expect(afterFirstPresign.uploadState).toBe('uploading');
    expect(afterFirstPresign.storageKey).toBe(firstPresign.body.storageKey);

    const retryPresign = await request(app.server)
      .post(`/artifacts/${artifactRes.body.id}/presign`)
      .set('Authorization', `Bearer ${token}`)
      .send();

    expect(retryPresign.status).toBe(200);
    expect(retryPresign.body.storageKey).toBe(firstPresign.body.storageKey);
    expect(typeof retryPresign.body.uploadUrl).toBe('string');

    s3Mock.on(HeadObjectCommand).resolves({ ContentLength: 128 });

    const confirmRes = await request(app.server)
      .post(`/artifacts/${artifactRes.body.id}/confirm`)
      .set('Authorization', `Bearer ${token}`)
      .send();

    expect(confirmRes.status).toBe(200);
    expect(confirmRes.body.uploadState).toBe('uploaded');

    const presignUploaded = await request(app.server)
      .post(`/artifacts/${artifactRes.body.id}/presign`)
      .set('Authorization', `Bearer ${token}`)
      .send();

    expect(presignUploaded.status).toBe(409);
    expect(presignUploaded.body.error?.code).toBe('UPLOAD_INVALID');
  });

  it('repairs a matching pending artifact created before size binding was introduced', async () => {
    const token = await login('student');
    const entry = await prisma.practiceEntry.create({
      data: {
        id: 'entry-legacy-artifact',
        courseId: 'COURSE_TEST',
        studentId: 'student-1',
        practiceDate: new Date(),
        goalText: 'Resume an older upload',
        tags: [],
        status: 'draft',
      },
    });
    await prisma.artifact.create({
      data: {
        id: 'artifact-legacy-pending',
        entryId: entry.id,
        type: 'audio',
        durationSeconds: 30,
      },
    });

    const response = await request(app.server)
      .post(`/entries/${entry.id}/artifacts`)
      .set('Authorization', `Bearer ${token}`)
      .send({
        id: 'artifact-legacy-pending',
        type: 'audio',
        durationSeconds: 30,
        sizeBytes: 128,
      });

    expect(response.status).toBe(200);
    expect(response.body.expectedSizeBytes).toBe(128);
  });

  it('verifies and repairs a matching uploaded legacy artifact', async () => {
    const token = await login('student');
    const entry = await prisma.practiceEntry.create({
      data: {
        id: 'entry-legacy-uploaded',
        courseId: 'COURSE_TEST',
        studentId: 'student-1',
        practiceDate: new Date(),
        goalText: 'Recover confirmed upload',
        tags: [],
        status: 'submitted',
      },
    });
    await prisma.artifact.create({
      data: {
        id: 'artifact-legacy-uploaded',
        entryId: entry.id,
        type: 'audio',
        durationSeconds: 30,
        uploadState: 'uploaded',
        storageKey: 'artifacts/legacy-uploaded',
      },
    });
    s3Mock.on(HeadObjectCommand).resolves({ ContentLength: 128 });

    const payload = {
      id: 'artifact-legacy-uploaded',
      type: 'audio',
      durationSeconds: 30,
      sizeBytes: 128,
    };
    const responses = await Promise.all([
      request(app.server)
        .post(`/entries/${entry.id}/artifacts`)
        .set('Authorization', `Bearer ${token}`)
        .send(payload),
      request(app.server)
        .post(`/entries/${entry.id}/artifacts`)
        .set('Authorization', `Bearer ${token}`)
        .send(payload),
    ]);

    expect(responses.map((response) => response.status)).toEqual([200, 200]);
    expect(responses.map((response) => response.body.expectedSizeBytes)).toEqual([128, 128]);
  });

  it('rejects a legacy uploaded artifact when its stored size differs', async () => {
    const token = await login('student');
    const entry = await prisma.practiceEntry.create({
      data: {
        id: 'entry-legacy-size-mismatch',
        courseId: 'COURSE_TEST',
        studentId: 'student-1',
        practiceDate: new Date(),
        goalText: 'Reject mismatched legacy upload',
        tags: [],
        status: 'draft',
      },
    });
    await prisma.artifact.create({
      data: {
        id: 'artifact-legacy-size-mismatch',
        entryId: entry.id,
        type: 'audio',
        durationSeconds: 30,
        uploadState: 'uploaded',
        storageKey: 'artifacts/legacy-size-mismatch',
      },
    });
    s3Mock.on(HeadObjectCommand).resolves({ ContentLength: 64 });

    const response = await request(app.server)
      .post(`/entries/${entry.id}/artifacts`)
      .set('Authorization', `Bearer ${token}`)
      .send({
        id: 'artifact-legacy-size-mismatch',
        type: 'audio',
        durationSeconds: 30,
        sizeBytes: 128,
      });

    expect(response.status).toBe(409);
    expect(response.body.error?.code).toBe('ID_CONFLICT');
    await expect(
      prisma.artifact.findUniqueOrThrow({ where: { id: 'artifact-legacy-size-mismatch' } })
    ).resolves.toMatchObject({ expectedSizeBytes: null });
  });

  it('presigns video uploads with a video content type', async () => {
    const token = await login('student');

    const entry = await prisma.practiceEntry.create({
      data: {
        id: 'entry-video-row',
        courseId: 'COURSE_TEST',
        studentId: 'student-1',
        practiceDate: new Date(),
        goalText: 'Legacy video row',
        tags: ['tag'],
        status: 'draft',
      },
    });
    const artifact = await prisma.artifact.create({
      data: {
        id: 'artifact-video-row',
        entryId: entry.id,
        type: 'video',
        durationSeconds: 30,
        expectedSizeBytes: 128,
      },
    });

    const presignRes = await request(app.server)
      .post(`/artifacts/${artifact.id}/presign`)
      .set('Authorization', `Bearer ${token}`)
      .send();

    expect(presignRes.status).toBe(200);
    expect(typeof presignRes.body.uploadUrl).toBe('string');
    expect(presignRes.body.requiredHeaders?.['Content-Type']).toBe('video/mp4');
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
      .send({ id: 'artifact-2', type: 'audio', durationSeconds: 30, sizeBytes: 128 });
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
      .send({ id: 'artifact-3', type: 'audio', durationSeconds: 30, sizeBytes: 128 });
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

  it('authorizes uploaded artifact playback for the owner and course teacher', async () => {
    const studentToken = await login('student');
    const teacherToken = await login('teacher');
    const entry = await prisma.practiceEntry.create({
      data: {
        id: 'entry-download',
        courseId: 'COURSE_TEST',
        studentId: 'student-1',
        practiceDate: new Date(),
        goalText: 'Review this evidence',
        tags: [],
        status: 'submitted',
      },
    });
    const artifact = await prisma.artifact.create({
      data: {
        id: 'artifact-download',
        entryId: entry.id,
        type: 'audio',
        durationSeconds: 30,
        uploadState: 'uploaded',
        storageKey: 'artifacts/entry-download/artifact-download',
      },
    });
    s3Mock.on(GetObjectCommand).resolves({});

    for (const token of [studentToken, teacherToken]) {
      const response = await request(app.server)
        .get(`/artifacts/${artifact.id}/download`)
        .set('Authorization', `Bearer ${token}`);
      expect(response.status).toBe(200);
      expect(response.headers['cache-control']).toBe('no-store');
      expect(response.body.expiresInSeconds).toBe(900);
      expect(response.body.downloadUrl).toMatch(/^https?:\/\//);
    }
  });

  it('rejects unavailable artifacts and unrelated students for playback', async () => {
    const otherStudent = await prisma.user.create({
      data: { id: 'student-download-other', displayName: 'Other', globalRole: 'student' },
    });
    await prisma.membership.create({
      data: {
        userId: otherStudent.id,
        courseId: 'COURSE_TEST',
        roleInCourse: 'student',
      },
    });
    const ownerToken = await login('student');
    const otherToken = await getAccessToken('student', { userId: otherStudent.id });
    const entry = await prisma.practiceEntry.create({
      data: {
        id: 'entry-download-denied',
        courseId: 'COURSE_TEST',
        studentId: 'student-1',
        practiceDate: new Date(),
        goalText: 'Private evidence',
        tags: [],
        status: 'draft',
      },
    });
    const artifact = await prisma.artifact.create({
      data: {
        id: 'artifact-download-denied',
        entryId: entry.id,
        type: 'audio',
        durationSeconds: 30,
      },
    });

    const unavailable = await request(app.server)
      .get(`/artifacts/${artifact.id}/download`)
      .set('Authorization', `Bearer ${ownerToken}`);
    expect(unavailable.status).toBe(409);
    expect(unavailable.body.error?.code).toBe('UPLOAD_INVALID');

    const denied = await request(app.server)
      .get(`/artifacts/${artifact.id}/download`)
      .set('Authorization', `Bearer ${otherToken}`);
    expect(denied.status).toBe(403);
  });
});
