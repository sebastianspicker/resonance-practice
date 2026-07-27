// Verifies entry filtering and cursor pagination without weakening course visibility rules.
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import { PrismaClient } from '@prisma/client';

function listEntries(app: any, accessToken: string, query = '') {
  return app.inject({
    method: 'GET',
    url: `/courses/COURSE_101/entries${query}`,
    headers: { authorization: `Bearer ${accessToken}` },
  });
}

function expectInvalidCursor(res: { statusCode: number; json: () => any }) {
  const body = res.json();
  expect(res.statusCode).toBe(400);
  expect(body.error.code).toBe('VALIDATION_ERROR');
  expect(body.error.message).toContain('cursor');
}

describe('GET /courses/:courseId/entries status filter', () => {
  let app: any;
  let prisma: PrismaClient;
  let accessToken: string;

  beforeAll(async () => {
    vi.resetModules();
    const { buildServer } = await import('../src/server.js');

    prisma = new PrismaClient();
    app = buildServer(prisma, {} as any);
    await prisma.$connect();
    await app.ready();

    // Get a dev auth token
    const issueRes = await app.inject({
      method: 'POST',
      url: '/dev/issue',
      payload: { role: 'student' },
    });
    const code = issueRes.json().code;
    const sessionRes = await app.inject({
      method: 'POST',
      url: '/auth/session',
      payload: { code },
    });
    accessToken = sessionRes.json().accessToken;
  });

  afterAll(async () => {
    await app.close();
    await prisma.$disconnect();
  });

  it('rejects invalid status filter with VALIDATION_ERROR', async () => {
    const res = await listEntries(app, accessToken, '?status=invalid');
    const body = res.json();
    expect(res.statusCode).toBe(400);
    expect(body.error.code).toBe('VALIDATION_ERROR');
    expect(body.error.message).toContain('Invalid status filter');
  });

  it('accepts valid status filter (draft)', async () => {
    const res = await listEntries(app, accessToken, '?status=draft');
    expect(res.statusCode).toBe(200);
    expect(Array.isArray(res.json().items)).toBe(true);
  });

  it('accepts valid status filter (submitted)', async () => {
    const res = await listEntries(app, accessToken, '?status=submitted');
    expect(res.statusCode).toBe(200);
    expect(Array.isArray(res.json().items)).toBe(true);
  });

  it('accepts valid status filter (reviewed)', async () => {
    const res = await listEntries(app, accessToken, '?status=reviewed');
    expect(res.statusCode).toBe(200);
    expect(Array.isArray(res.json().items)).toBe(true);
  });

  it('returns all entries when no status filter is provided (student)', async () => {
    const res = await listEntries(app, accessToken);
    expect(res.statusCode).toBe(200);
    expect(Array.isArray(res.json().items)).toBe(true);
  });

  it('rejects unknown cursor id with VALIDATION_ERROR', async () => {
    // cursor references a non-existent entry → 400 invalid cursor
    const res = await listEntries(app, accessToken, '?cursor=nonexistent-entry');
    expectInvalidCursor(res);
  });

  it('rejects cursor ids outside the visible student entry scope', async () => {
    await prisma.user.upsert({
      where: { id: 'cursor-foreign-student' },
      update: {},
      create: {
        id: 'cursor-foreign-student',
        displayName: 'Foreign Student',
        globalRole: 'student',
      },
    });
    await prisma.course.upsert({
      where: { id: 'COURSE_CURSOR_FOREIGN' },
      update: {},
      create: { id: 'COURSE_CURSOR_FOREIGN', title: 'Foreign Cursor Course' },
    });
    await prisma.practiceEntry.upsert({
      where: { id: 'foreign-cursor-entry' },
      update: {},
      create: {
        id: 'foreign-cursor-entry',
        courseId: 'COURSE_CURSOR_FOREIGN',
        studentId: 'cursor-foreign-student',
        practiceDate: new Date('2025-01-01T10:00:00.000Z'),
        goalText: 'Foreign cursor',
        tags: [],
        status: 'submitted',
      },
    });

    const res = await listEntries(app, accessToken, '?cursor=foreign-cursor-entry');
    expectInvalidCursor(res);
  });
});
