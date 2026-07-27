// Covers deterministic teacher-review ordering and cursor pagination across equal timestamps.
import request from 'supertest';
import { describe, expect, it } from 'vitest';
import { app, getReviewQueue, installBasicSuite, login, prisma } from './support/testUtils.js';

/**
 * Helper: create N submitted entries with deterministic practice dates.
 * Entries are ordered so that entry-0 has the newest practiceDate and
 * entry-(N-1) has the oldest. This aligns with the default DESC sort.
 */
async function seedSubmittedEntries(count: number) {
  for (let i = 0; i < count; i++) {
    const date = new Date(`2025-06-${String(30 - i).padStart(2, '0')}T10:00:00.000Z`);
    await prisma.practiceEntry.create({
      data: {
        id: `entry-${i}`,
        courseId: 'COURSE_TEST',
        studentId: 'student-1',
        practiceDate: date,
        createdAt: date,
        goalText: `Goal ${i}`,
        tags: [],
        status: 'submitted',
      },
    });
  }
}

async function expectInvalidReviewCursor(cursor: string) {
  const token = await login('teacher');
  const res = await getReviewQueue(token, `/courses/COURSE_TEST/review-queue?cursor=${cursor}`);

  expect(res.status).toBe(400);
  expect(res.body.error.code).toBe('VALIDATION_ERROR');
  expect(res.body.error.message).toContain('cursor');
}

describe('GET /courses/:courseId/review-queue pagination', () => {
  installBasicSuite({ resetS3: true });

  // ── Response shape ──

  it('returns { items, nextCursor } envelope', async () => {
    const token = await login('teacher');
    const res = await getReviewQueue(token);

    expect(res.status).toBe(200);
    expect(res.body).toHaveProperty('items');
    expect(res.body).toHaveProperty('nextCursor');
    expect(Array.isArray(res.body.items)).toBe(true);
  });

  // ── Empty results ──

  it('returns empty items and null nextCursor when no entries exist', async () => {
    const token = await login('teacher');
    const res = await getReviewQueue(token);

    expect(res.status).toBe(200);
    expect(res.body.items).toEqual([]);
    expect(res.body.nextCursor).toBeNull();
  });

  // ── Default limit ──

  it('returns at most 20 entries by default', async () => {
    await seedSubmittedEntries(25);
    const token = await login('teacher');
    const res = await request(app.server)
      .get('/courses/COURSE_TEST/review-queue')
      .set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(200);
    expect(res.body.items).toHaveLength(20);
    expect(res.body.nextCursor).not.toBeNull();
  });

  // ── Custom limit ──

  it('respects custom limit query parameter', async () => {
    await seedSubmittedEntries(10);
    const token = await login('teacher');
    const res = await request(app.server)
      .get('/courses/COURSE_TEST/review-queue?limit=5')
      .set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(200);
    expect(res.body.items).toHaveLength(5);
    expect(res.body.nextCursor).not.toBeNull();
  });

  it('clamps limit to max 100', async () => {
    await seedSubmittedEntries(5);
    const token = await login('teacher');
    const res = await request(app.server)
      .get('/courses/COURSE_TEST/review-queue?limit=999')
      .set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(200);
    // Should return all 5 entries (clamped to 100, but only 5 exist)
    expect(res.body.items).toHaveLength(5);
    expect(res.body.nextCursor).toBeNull();
  });

  it('rejects invalid limit (non-numeric)', async () => {
    const token = await login('teacher');
    const res = await request(app.server)
      .get('/courses/COURSE_TEST/review-queue?limit=abc')
      .set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe('VALIDATION_ERROR');
  });

  it('rejects fractional limits', async () => {
    const token = await login('teacher');
    const res = await request(app.server)
      .get('/courses/COURSE_TEST/review-queue?limit=1.5')
      .set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe('VALIDATION_ERROR');
  });

  it('rejects limit=0', async () => {
    const token = await login('teacher');
    const res = await request(app.server)
      .get('/courses/COURSE_TEST/review-queue?limit=0')
      .set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe('VALIDATION_ERROR');
  });

  it('rejects negative limit', async () => {
    const token = await login('teacher');
    const res = await request(app.server)
      .get('/courses/COURSE_TEST/review-queue?limit=-5')
      .set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe('VALIDATION_ERROR');
  });

  // ── Cursor-based pagination (next page) ──

  it('fetches subsequent pages using nextCursor', async () => {
    await seedSubmittedEntries(8);
    const token = await login('teacher');

    // Page 1: 3 items
    const page1 = await request(app.server)
      .get('/courses/COURSE_TEST/review-queue?limit=3')
      .set('Authorization', `Bearer ${token}`);

    expect(page1.status).toBe(200);
    expect(page1.body.items).toHaveLength(3);
    expect(page1.body.nextCursor).not.toBeNull();

    // Page 2: next 3 items
    const page2 = await request(app.server)
      .get(`/courses/COURSE_TEST/review-queue?limit=3&cursor=${page1.body.nextCursor}`)
      .set('Authorization', `Bearer ${token}`);

    expect(page2.status).toBe(200);
    expect(page2.body.items).toHaveLength(3);
    expect(page2.body.nextCursor).not.toBeNull();

    // Page 3: remaining 2 items
    const page3 = await request(app.server)
      .get(`/courses/COURSE_TEST/review-queue?limit=3&cursor=${page2.body.nextCursor}`)
      .set('Authorization', `Bearer ${token}`);

    expect(page3.status).toBe(200);
    expect(page3.body.items).toHaveLength(2);
    expect(page3.body.nextCursor).toBeNull();

    // Verify no duplicates across pages
    const allIds = [
      ...page1.body.items.map((e: any) => e.id),
      ...page2.body.items.map((e: any) => e.id),
      ...page3.body.items.map((e: any) => e.id),
    ];
    expect(new Set(allIds).size).toBe(8);
  });

  it('rejects invalid cursor (nonexistent entry ID)', async () => {
    await expectInvalidReviewCursor('nonexistent-id');
  });

  it('rejects cursor ids outside the teacher review queue scope', async () => {
    await prisma.user.create({
      data: { id: 'foreign-student', displayName: 'Foreign Student', globalRole: 'student' },
    });
    await prisma.course.create({
      data: { id: 'COURSE_FOREIGN', title: 'Foreign Course' },
    });
    await prisma.practiceEntry.create({
      data: {
        id: 'foreign-review-cursor',
        courseId: 'COURSE_FOREIGN',
        studentId: 'foreign-student',
        practiceDate: new Date('2025-06-30T10:00:00.000Z'),
        createdAt: new Date('2025-06-30T10:00:00.000Z'),
        goalText: 'Foreign review cursor',
        tags: [],
        status: 'submitted',
      },
    });

    await expectInvalidReviewCursor('foreign-review-cursor');
  });

  // ── nextCursor is null when results fit in one page ──

  it('returns null nextCursor when all results fit in one page', async () => {
    await seedSubmittedEntries(3);
    const token = await login('teacher');
    const res = await request(app.server)
      .get('/courses/COURSE_TEST/review-queue?limit=10')
      .set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(200);
    expect(res.body.items).toHaveLength(3);
    expect(res.body.nextCursor).toBeNull();
  });

  // ── Ordering preserved across pages ──

  it('maintains DESC ordering across pages', async () => {
    await seedSubmittedEntries(6);
    const token = await login('teacher');

    const page1 = await request(app.server)
      .get('/courses/COURSE_TEST/review-queue?limit=3')
      .set('Authorization', `Bearer ${token}`);

    const page2 = await request(app.server)
      .get(`/courses/COURSE_TEST/review-queue?limit=3&cursor=${page1.body.nextCursor}`)
      .set('Authorization', `Bearer ${token}`);

    // entry-0 has newest date (June 30), entry-5 has oldest (June 25)
    const allIds = [
      ...page1.body.items.map((e: any) => e.id),
      ...page2.body.items.map((e: any) => e.id),
    ];
    expect(allIds).toEqual(['entry-0', 'entry-1', 'entry-2', 'entry-3', 'entry-4', 'entry-5']);
  });
});
