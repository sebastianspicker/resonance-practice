import request from 'supertest';
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import { PrismaClient } from '@prisma/client';

describe('GET /courses/:courseId/entries status filter', () => {
  let app: any;
  let prisma: PrismaClient;
  let accessToken: string;

  beforeAll(async () => {
    vi.resetModules();
    const { buildServer } = await import('../src/server.js');

    prisma = new PrismaClient();
    app = buildServer(prisma, {} as any);
    await app.ready();

    // Get a dev auth token
    const issueRes = await request(app.server).post('/dev/issue').send({ role: 'student' });
    const code = issueRes.body.code;
    const sessionRes = await request(app.server).post('/auth/session').send({ code });
    accessToken = sessionRes.body.accessToken;
  });

  afterAll(async () => {
    await app.close();
    await prisma.$disconnect();
  });

  it('rejects invalid status filter with VALIDATION_ERROR', async () => {
    const res = await request(app.server)
      .get('/courses/COURSE_101/entries?status=invalid')
      .set('Authorization', `Bearer ${accessToken}`);
    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe('VALIDATION_ERROR');
    expect(res.body.error.message).toContain('Invalid status filter');
  });

  it('accepts valid status filter (draft)', async () => {
    const res = await request(app.server)
      .get('/courses/COURSE_101/entries?status=draft')
      .set('Authorization', `Bearer ${accessToken}`);
    expect(res.status).toBe(200);
    expect(Array.isArray(res.body.items)).toBe(true);
  });

  it('accepts valid status filter (submitted)', async () => {
    const res = await request(app.server)
      .get('/courses/COURSE_101/entries?status=submitted')
      .set('Authorization', `Bearer ${accessToken}`);
    expect(res.status).toBe(200);
    expect(Array.isArray(res.body.items)).toBe(true);
  });

  it('accepts valid status filter (reviewed)', async () => {
    const res = await request(app.server)
      .get('/courses/COURSE_101/entries?status=reviewed')
      .set('Authorization', `Bearer ${accessToken}`);
    expect(res.status).toBe(200);
    expect(Array.isArray(res.body.items)).toBe(true);
  });

  it('returns all entries when no status filter is provided (student)', async () => {
    const res = await request(app.server)
      .get('/courses/COURSE_101/entries')
      .set('Authorization', `Bearer ${accessToken}`);
    expect(res.status).toBe(200);
    expect(Array.isArray(res.body.items)).toBe(true);
  });

  it('rejects unknown cursor id with VALIDATION_ERROR', async () => {
    // cursor references a non-existent entry → 400 invalid cursor
    const res = await request(app.server)
      .get('/courses/COURSE_101/entries?cursor=nonexistent-entry')
      .set('Authorization', `Bearer ${accessToken}`);
    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe('VALIDATION_ERROR');
    expect(res.body.error.message).toContain('cursor');
  });
});
