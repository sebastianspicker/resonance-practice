import request from 'supertest';
import { describe, expect, it } from 'vitest';
import { app, getAccessToken, prisma } from './support/testUtils.js';
import { openSession } from './support/sessionHttp.js';
import {
  enrollCourseMember,
  installV1SyncSuite,
  seedArtifact,
  seedEntry,
} from './v1-sync/support.js';

describe('v1 read authorization', () => {
  const suite = installV1SyncSuite();
  const get = (path: string, token: string) =>
    request(app.server).get(path).set('authorization', `Bearer ${token}`);
  const post = (path: string, token: string) =>
    request(app.server).post(path).set('authorization', `Bearer ${token}`).send();

  async function seedVisibilityFixture() {
    const other = await enrollCourseMember('student', 'student-2', 'Other Student');
    await prisma.user.create({
      data: { id: 'outsider', displayName: 'Out', globalRole: 'student' },
    });
    const outsider = await getAccessToken('student', { userId: 'outsider' });
    await seedEntry('own-draft', 'student-1', {
      practiceDate: new Date('2026-07-01T00:00:00.000Z'),
    });
    await seedEntry('own-submitted', 'student-1', {
      status: 'submitted',
      practiceDate: new Date('2026-07-02T00:00:00.000Z'),
    });
    await seedEntry('own-reviewed', 'student-1', {
      status: 'reviewed',
      practiceDate: new Date('2026-07-03T00:00:00.000Z'),
    });
    await seedEntry('other-draft', 'student-2', { goalText: 'Other draft' });
    await seedEntry('other-submitted', 'student-2', {
      status: 'submitted',
      practiceDate: new Date('2026-07-04T00:00:00.000Z'),
    });
    return { other, outsider };
  }

  const ids = (response: { body: { items: Array<{ id: string }> } }) =>
    response.body.items.map((item) => item.id);

  it('lists course memberships with the caller role in each course', async () => {
    await prisma.course.create({ data: { id: 'COURSE_A', title: 'Another Course' } });
    await prisma.membership.create({
      data: { userId: 'student-1', courseId: 'COURSE_A', roleInCourse: 'teacher' },
    });
    const student = await get('/api/v1/courses', suite.studentToken);
    expect(student.status).toBe(200);
    expect(student.body).toEqual([
      { id: 'COURSE_A', title: 'Another Course', roleInCourse: 'teacher' },
      { id: 'COURSE_TEST', title: 'Test Course', roleInCourse: 'student' },
    ]);
    const teacher = await get('/api/v1/courses', suite.teacherToken);
    expect(teacher.body).toEqual([
      { id: 'COURSE_TEST', title: 'Test Course', roleInCourse: 'teacher' },
    ]);
    expect((await request(app.server).get('/api/v1/courses')).status).toBe(401);
  });

  it('scopes entry lists by course role and status', async () => {
    const { other, outsider } = await seedVisibilityFixture();
    const list = (query = '', token = suite.studentToken) =>
      get(`/api/v1/courses/COURSE_TEST/entries${query}`, token);

    const own = await list();
    expect(own.status).toBe(200);
    expect(ids(own)).toEqual(['own-reviewed', 'own-submitted', 'own-draft']);
    expect(own.body.nextCursor).toBeNull();
    expect(ids(await list('?status=submitted'))).toEqual(['own-submitted']);
    expect(ids(await list('', other))).toEqual(
      expect.arrayContaining(['other-submitted', 'other-draft'])
    );
    expect(ids(await list('', other))).toHaveLength(2);

    expect(ids(await list('', suite.teacherToken))).toEqual(['other-submitted', 'own-submitted']);
    expect(ids(await list('?status=reviewed', suite.teacherToken))).toEqual(['own-reviewed']);
    const draft = await list('?status=draft', suite.teacherToken);
    expect(draft.status).toBe(403);
    expect(draft.body.error.code).toBe('ENTRY_ACCESS_DENIED');

    const nonMember = await list('', outsider);
    expect(nonMember.status).toBe(403);
    expect(nonMember.body.error.code).toBe('COURSE_ACCESS_DENIED');
    const invalid = await list('?status=bogus');
    expect(invalid.status).toBe(400);
    expect(invalid.body.error.code).toBe('VALIDATION_ERROR');
  });

  it('applies ownership, draft, membership, and existence rules to entry detail reads', async () => {
    const { other, outsider } = await seedVisibilityFixture();
    await seedArtifact('own-audio', 'own-submitted');
    const detail = (id: string, token: string) => get(`/api/v1/entries/${id}`, token);
    const denied = async (id: string, token: string, status: number, code: string) => {
      const response = await detail(id, token);
      expect([response.status, response.body.error.code]).toEqual([status, code]);
    };

    const owner = await detail('own-submitted', suite.studentToken);
    expect(owner.status).toBe(200);
    expect(owner.body).toMatchObject({
      id: 'own-submitted',
      status: 'submitted',
      captureMarkers: [],
    });
    expect(owner.body.artifacts).toHaveLength(1);
    expect(owner.body.artifacts[0]).not.toHaveProperty('storageKey');
    expect((await detail('own-submitted', suite.teacherToken)).status).toBe(200);

    await denied('own-draft', suite.teacherToken, 403, 'ENTRY_ACCESS_DENIED');
    await denied('own-submitted', other, 403, 'ENTRY_ACCESS_DENIED');
    await denied('own-submitted', outsider, 403, 'COURSE_ACCESS_DENIED');
    await denied('missing-entry', suite.studentToken, 404, 'ENTRY_NOT_FOUND');
  });

  it('serves the review queue to teachers only, with student names and marker counts', async () => {
    const { other, outsider } = await seedVisibilityFixture();
    await seedEntry('lesson-submitted', 'student-2', {
      status: 'submitted',
      kind: 'teaching_lesson',
      practiceDate: new Date('2026-07-10T00:00:00.000Z'),
    });
    await seedArtifact('lesson-video', 'lesson-submitted', { type: 'video' });
    await prisma.captureMarker.create({
      data: {
        id: 'lesson-marker',
        entryId: 'lesson-submitted',
        artifactId: 'lesson-video',
        studentId: 'student-2',
        timeSeconds: 3,
        kind: 'privacy_note',
      },
    });
    const queue = '/api/v1/courses/COURSE_TEST/review-queue';

    const asTeacher = await get(queue, suite.teacherToken);
    expect(asTeacher.status).toBe(200);
    expect(ids(asTeacher)).toEqual(['lesson-submitted', 'other-submitted', 'own-submitted']);
    expect(asTeacher.body.items[0]).toMatchObject({
      studentName: 'Other Student',
      captureMarkerCount: 1,
    });
    expect(asTeacher.body.items[2]).toMatchObject({
      studentName: 'Student',
      captureMarkerCount: 0,
    });

    for (const token of [suite.studentToken, other]) {
      const response = await get(queue, token);
      expect([response.status, response.body.error.code]).toEqual([403, 'TEACHER_ONLY']);
    }
    const nonMember = await get(queue, outsider);
    expect([nonMember.status, nonMember.body.error.code]).toEqual([403, 'COURSE_ACCESS_DENIED']);
  });

  it('issues download sessions only for uploaded artifacts the caller may see', async () => {
    const { other, outsider } = await seedVisibilityFixture();
    await seedArtifact('draft-audio', 'own-draft');
    await seedArtifact('submitted-audio', 'own-submitted');
    await seedArtifact('uploading-audio', 'own-submitted', { uploadState: 'uploading' });
    const download = (artifactId: string, token: string) =>
      post(`/api/v1/artifacts/${artifactId}/download-session`, token);
    const failure = async (artifactId: string, token: string) => {
      const response = await download(artifactId, token);
      return [response.status, response.body.error.code];
    };

    const owner = await download('draft-audio', suite.studentToken);
    expect(owner.status).toBe(200);
    expect(owner.headers['cache-control']).toBe('no-store');
    expect(owner.body.expiresInSeconds).toBe(900);
    expect(owner.body.downloadUrl).toEqual(expect.stringContaining('artifacts/final/own-draft/'));
    expect(Object.keys(owner.body).sort()).toEqual(['downloadUrl', 'expiresInSeconds']);
    expect((await download('submitted-audio', suite.teacherToken)).status).toBe(200);

    expect(await failure('uploading-audio', suite.studentToken)).toEqual([
      404,
      'ARTIFACT_NOT_FOUND',
    ]);
    expect(await failure('missing-artifact', suite.studentToken)).toEqual([
      404,
      'ARTIFACT_NOT_FOUND',
    ]);
    expect(await failure('draft-audio', other)).toEqual([403, 'ENTRY_ACCESS_DENIED']);
    expect(await failure('draft-audio', suite.teacherToken)).toEqual([403, 'ENTRY_ACCESS_DENIED']);
    expect(await failure('submitted-audio', outsider)).toEqual([403, 'COURSE_ACCESS_DENIED']);
  });

  it('returns the authenticated user and rejects missing or invalid bearer tokens', async () => {
    const me = await request(app.server)
      .get('/auth/me')
      .set('authorization', `Bearer ${suite.studentToken}`);
    expect(me.status).toBe(200);
    expect(me.body).toEqual({ id: 'student-1', displayName: 'Student', globalRole: 'student' });

    const missing = await request(app.server).get('/auth/me');
    expect([missing.status, missing.body.error.code]).toEqual([401, 'MISSING_AUTH']);
    const invalid = await request(app.server).get('/auth/me').set('authorization', 'Bearer nope');
    expect([invalid.status, invalid.body.error.code]).toEqual([401, 'INVALID_TOKEN']);
  });

  it('rotates refresh tokens and revokes them on logout', async () => {
    const session = await openSession('student-1', 'student');
    expect(session.status).toBe(201);
    expect(session.body.user).toEqual({
      id: 'student-1',
      displayName: 'Student',
      globalRole: 'student',
    });

    const rotated = await request(app.server)
      .post('/auth/refresh')
      .send({ refreshToken: session.body.refreshToken });
    expect(rotated.status).toBe(200);
    expect(rotated.body).toEqual({
      accessToken: expect.any(String),
      refreshToken: expect.any(String),
    });

    const logout = await request(app.server)
      .post('/auth/logout')
      .send({ refreshToken: rotated.body.refreshToken });
    expect(logout.status).toBe(200);
    expect(logout.body).toEqual({ success: true });
    const afterLogout = await request(app.server)
      .post('/auth/refresh')
      .send({ refreshToken: rotated.body.refreshToken });
    expect(afterLogout.status).toBe(401);
    expect(afterLogout.body.error.code).toBe('REFRESH_ALREADY_USED');
    expect(
      await prisma.refreshToken.count({ where: { userId: 'student-1', revokedAt: null } })
    ).toBe(0);
  });

  it('logs out through the access token when no refresh token is supplied', async () => {
    const session = await openSession('student-1', 'student');
    const anonymous = await request(app.server).post('/auth/logout').send();
    expect([anonymous.status, anonymous.body.error.code]).toEqual([401, 'MISSING_AUTH']);

    const logout = await request(app.server)
      .post('/auth/logout')
      .set('authorization', `Bearer ${session.body.accessToken}`)
      .send();
    expect(logout.status).toBe(200);
    const refreshed = await request(app.server)
      .post('/auth/refresh')
      .send({ refreshToken: session.body.refreshToken });
    expect([refreshed.status, refreshed.body.error.code]).toEqual([401, 'REFRESH_ALREADY_USED']);
  });
});
