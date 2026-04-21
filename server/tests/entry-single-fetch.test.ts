import request from 'supertest';
import { beforeAll, afterAll, beforeEach, describe, expect, it } from 'vitest';
import {
  app,
  setupApp,
  teardownApp,
  resetDb,
  seedBasic,
  getAccessToken,
  prisma,
} from './testUtils.js';

function login(role: 'student' | 'teacher') {
  const userId = role === 'student' ? 'student-1' : 'teacher-1';
  return getAccessToken(role, { userId });
}

describe('GET /entries/:entryId', () => {
  let entryId: string;

  beforeAll(async () => {
    await setupApp();
  });

  afterAll(async () => {
    await teardownApp();
  });

  beforeEach(async () => {
    await resetDb();
    await seedBasic();
    entryId = 'entry-single-fetch-1';
    await prisma.practiceEntry.create({
      data: {
        id: entryId,
        courseId: 'COURSE_TEST',
        studentId: 'student-1',
        practiceDate: new Date('2024-03-01'),
        goalText: 'Improve tone quality',
        durationSeconds: 1800,
        tags: ['technique', 'tone'],
        notes: 'Focused on long tones',
        status: 'draft',
      },
    });
  });

  it('returns the entry with artifacts for the owning student', async () => {
    const token = await login('student');
    const res = await request(app.server)
      .get(`/entries/${entryId}`)
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(200);
    expect(res.body.id).toBe(entryId);
    expect(res.body.courseId).toBe('COURSE_TEST');
    expect(res.body.studentId).toBe('student-1');
    expect(res.body.goalText).toBe('Improve tone quality');
    expect(res.body.tags).toEqual(['technique', 'tone']);
    expect(res.body.artifacts).toEqual([]);
  });

  it('includes artifacts ordered by createdAt asc', async () => {
    await prisma.artifact.createMany({
      data: [
        { id: 'art-b', entryId, type: 'audio', durationSeconds: 60 },
        { id: 'art-a', entryId, type: 'video', durationSeconds: 120 },
      ],
    });
    const token = await login('student');
    const res = await request(app.server)
      .get(`/entries/${entryId}`)
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(200);
    expect(res.body.artifacts).toHaveLength(2);
    // Both artifacts should be present; order is createdAt asc (insertion order here)
    const ids = res.body.artifacts.map((a: { id: string }) => a.id);
    expect(ids).toContain('art-a');
    expect(ids).toContain('art-b');
  });

  it('returns the entry for a teacher enrolled in the same course', async () => {
    const token = await login('teacher');
    const res = await request(app.server)
      .get(`/entries/${entryId}`)
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(200);
    expect(res.body.id).toBe(entryId);
    expect(Array.isArray(res.body.artifacts)).toBe(true);
  });

  it('returns 404 for a non-existent entry', async () => {
    const token = await login('student');
    const res = await request(app.server)
      .get('/entries/does-not-exist')
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(404);
    expect(res.body.error?.code).toBe('ENTRY_NOT_FOUND');
  });

  it('returns 410 for a soft-deleted entry', async () => {
    await prisma.practiceEntry.update({
      where: { id: entryId },
      data: { deletedAt: new Date() },
    });
    const token = await login('student');
    const res = await request(app.server)
      .get(`/entries/${entryId}`)
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(410);
    expect(res.body.error?.code).toBe('ENTRY_DELETED');
  });

  it('returns 403 when a different student in the same course requests the entry', async () => {
    const other = await prisma.user.create({
      data: { id: 'student-other', displayName: 'Other Student', globalRole: 'student' },
    });
    await prisma.membership.create({
      data: { userId: other.id, courseId: 'COURSE_TEST', roleInCourse: 'student' },
    });
    const token = await getAccessToken('student', { userId: other.id });
    const res = await request(app.server)
      .get(`/entries/${entryId}`)
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(403);
    expect(res.body.error?.code).toBe('ENTRY_ACCESS_DENIED');
  });

  it('returns 403 when a user not enrolled in the course requests the entry', async () => {
    const outsider = await prisma.user.create({
      data: { id: 'outsider-fetch', displayName: 'Outsider', globalRole: 'student' },
    });
    const token = await getAccessToken('student', { userId: outsider.id });
    const res = await request(app.server)
      .get(`/entries/${entryId}`)
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(403);
  });

  it('returns 401 for unauthenticated request', async () => {
    const res = await request(app.server).get(`/entries/${entryId}`);
    expect(res.status).toBe(401);
    expect(res.body.error?.code).toBe('MISSING_AUTH');
  });
});
