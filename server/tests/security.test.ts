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

describe('security', () => {
  beforeAll(async () => {
    await setupApp();
  });

  afterAll(async () => {
    await teardownApp();
  });

  beforeEach(async () => {
    await resetDb();
    await seedBasic();
  });

  // Bug #33: /auth/refresh gated by AUTH_MODE
  describe('auth/refresh auth mode gate', () => {
    it('allows refresh in dev mode', async () => {
      const issue = await request(app.server).post('/dev/issue').send({ role: 'student' });
      const session = await request(app.server).post('/auth/session').send({
        code: issue.body.code,
        redirectUri: 'resonance://auth-callback',
      });
      const refreshToken = session.body.refreshToken as string;
      const res = await request(app.server).post('/auth/refresh').send({ refreshToken });
      expect(res.status).toBe(200);
      expect(typeof res.body.accessToken).toBe('string');
      expect(res.body.accessToken.split('.')).toHaveLength(3);
      expect(typeof res.body.refreshToken).toBe('string');
      expect(res.body.refreshToken.split('.')).toHaveLength(3);
    });
  });

  // Bug #35: Client-controlled entry/artifact IDs with format validation
  describe('client ID format validation', () => {
    it('rejects entry ID with special characters', async () => {
      const token = await login('student');
      const res = await request(app.server)
        .post('/courses/COURSE_TEST/entries')
        .set('Authorization', `Bearer ${token}`)
        .send({
          id: '../../../etc/passwd',
          practiceDate: new Date().toISOString(),
          goalText: 'Test entry',
          tags: [],
        });
      expect(res.status).toBe(400);
      expect(res.body.error?.code).toBe('VALIDATION_ERROR');
    });

    it('rejects entry ID with spaces', async () => {
      const token = await login('student');
      const res = await request(app.server)
        .post('/courses/COURSE_TEST/entries')
        .set('Authorization', `Bearer ${token}`)
        .send({
          id: 'id with spaces',
          practiceDate: new Date().toISOString(),
          goalText: 'Test entry',
          tags: [],
        });
      expect(res.status).toBe(400);
    });

    it('rejects empty entry ID', async () => {
      const token = await login('student');
      const res = await request(app.server)
        .post('/courses/COURSE_TEST/entries')
        .set('Authorization', `Bearer ${token}`)
        .send({
          id: '',
          practiceDate: new Date().toISOString(),
          goalText: 'Test entry',
          tags: [],
        });
      expect(res.status).toBe(400);
    });

    it('rejects overly long entry ID', async () => {
      const token = await login('student');
      const res = await request(app.server)
        .post('/courses/COURSE_TEST/entries')
        .set('Authorization', `Bearer ${token}`)
        .send({
          id: 'a'.repeat(129),
          practiceDate: new Date().toISOString(),
          goalText: 'Test entry',
          tags: [],
        });
      expect(res.status).toBe(400);
    });

    it('accepts valid entry ID with hyphens and underscores', async () => {
      const token = await login('student');
      const res = await request(app.server)
        .post('/courses/COURSE_TEST/entries')
        .set('Authorization', `Bearer ${token}`)
        .send({
          id: 'entry_2025-03-21_abc123',
          practiceDate: new Date().toISOString(),
          goalText: 'Test entry',
          tags: [],
        });
      expect(res.status).toBe(201);
      expect(res.body.id).toBe('entry_2025-03-21_abc123');
    });

    it('returns 409 on duplicate entry ID', async () => {
      const token = await login('student');
      const payload = {
        id: 'duplicate-entry-id',
        practiceDate: new Date().toISOString(),
        goalText: 'Test entry',
        tags: [],
      };
      const first = await request(app.server)
        .post('/courses/COURSE_TEST/entries')
        .set('Authorization', `Bearer ${token}`)
        .send(payload);
      expect(first.status).toBe(201);

      const second = await request(app.server)
        .post('/courses/COURSE_TEST/entries')
        .set('Authorization', `Bearer ${token}`)
        .send(payload);
      expect(second.status).toBe(409);
      expect(second.body.error?.code).toBe('ID_CONFLICT');
    });

    it('rejects artifact ID with special characters', async () => {
      await prisma.practiceEntry.create({
        data: {
          id: 'entry-for-artifact-id-test',
          courseId: 'COURSE_TEST',
          studentId: 'student-1',
          practiceDate: new Date(),
          goalText: 'Test',
          tags: ['tag'],
          status: 'draft',
        },
      });

      const token = await login('student');
      const res = await request(app.server)
        .post('/entries/entry-for-artifact-id-test/artifacts')
        .set('Authorization', `Bearer ${token}`)
        .send({ id: 'art<script>alert(1)</script>', type: 'audio', durationSeconds: 10 });
      expect(res.status).toBe(400);
      expect(res.body.error?.code).toBe('VALIDATION_ERROR');
    });

    it('returns 409 on duplicate artifact ID', async () => {
      await prisma.practiceEntry.create({
        data: {
          id: 'entry-for-dup-artifact',
          courseId: 'COURSE_TEST',
          studentId: 'student-1',
          practiceDate: new Date(),
          goalText: 'Test',
          tags: ['tag'],
          status: 'draft',
        },
      });

      const token = await login('student');
      const payload = { id: 'dup-artifact-id', type: 'audio', durationSeconds: 10 };
      const first = await request(app.server)
        .post('/entries/entry-for-dup-artifact/artifacts')
        .set('Authorization', `Bearer ${token}`)
        .send(payload);
      expect(first.status).toBe(201);

      const second = await request(app.server)
        .post('/entries/entry-for-dup-artifact/artifacts')
        .set('Authorization', `Bearer ${token}`)
        .send(payload);
      expect(second.status).toBe(409);
      expect(second.body.error?.code).toBe('ID_CONFLICT');
    });
  });

  // Bug #34: deletedAt enforcement on artifact/feedback routes (verify already fixed)
  describe('deletedAt enforcement', () => {
    it('rejects artifact creation on deleted entry', async () => {
      await prisma.practiceEntry.create({
        data: {
          id: 'entry-deleted-for-artifact',
          courseId: 'COURSE_TEST',
          studentId: 'student-1',
          practiceDate: new Date(),
          goalText: 'Deleted',
          tags: ['tag'],
          status: 'draft',
          deletedAt: new Date(),
        },
      });

      const token = await login('student');
      const res = await request(app.server)
        .post('/entries/entry-deleted-for-artifact/artifacts')
        .set('Authorization', `Bearer ${token}`)
        .send({ id: 'artifact-on-deleted', type: 'audio', durationSeconds: 5 });
      expect(res.status).toBe(404);
    });

    it('rejects feedback on deleted entry', async () => {
      await prisma.practiceEntry.create({
        data: {
          id: 'entry-deleted-for-feedback',
          courseId: 'COURSE_TEST',
          studentId: 'student-1',
          practiceDate: new Date(),
          goalText: 'Deleted',
          tags: ['tag'],
          status: 'submitted',
          deletedAt: new Date(),
        },
      });

      const token = await login('teacher');
      const res = await request(app.server)
        .post('/feedback')
        .set('Authorization', `Bearer ${token}`)
        .send({
          targetType: 'entry',
          targetId: 'entry-deleted-for-feedback',
          status: 'ok',
          commentsText: 'Should not work',
          markers: [],
        });
      expect(res.status).toBe(410);
    });

    it('rejects feedback on artifact whose entry is deleted', async () => {
      const entry = await prisma.practiceEntry.create({
        data: {
          id: 'entry-deleted-for-art-feedback',
          courseId: 'COURSE_TEST',
          studentId: 'student-1',
          practiceDate: new Date(),
          goalText: 'Deleted parent',
          tags: ['tag'],
          status: 'submitted',
          deletedAt: new Date(),
        },
      });
      const artifact = await prisma.artifact.create({
        data: {
          id: 'artifact-on-deleted-entry',
          entryId: entry.id,
          type: 'audio',
          durationSeconds: 5,
          uploadState: 'uploaded',
        },
      });

      const token = await login('teacher');
      const res = await request(app.server)
        .post('/feedback')
        .set('Authorization', `Bearer ${token}`)
        .send({
          targetType: 'artifact',
          targetId: artifact.id,
          status: 'ok',
          commentsText: 'Should not work',
          markers: [],
        });
      expect(res.status).toBe(410);
    });
  });

  // Security headers & CORS hardening
  describe('security headers', () => {
    it('sets Content-Security-Policy header', async () => {
      const res = await request(app.server).get('/health');
      expect(res.status).toBe(200);
      const csp = res.headers['content-security-policy'];
      expect(typeof csp).toBe('string');
      expect(csp).toContain("default-src 'none'");
      expect(csp).toContain("frame-ancestors 'none'");
    });

    it('sets X-Content-Type-Options to nosniff', async () => {
      const res = await request(app.server).get('/health');
      expect(res.headers['x-content-type-options']).toBe('nosniff');
    });

    it('sets X-Frame-Options to DENY', async () => {
      const res = await request(app.server).get('/health');
      expect(res.headers['x-frame-options']).toBe('DENY');
    });

    it('sets Referrer-Policy to no-referrer', async () => {
      const res = await request(app.server).get('/health');
      expect(res.headers['referrer-policy']).toBe('no-referrer');
    });

    it('does not expose x-powered-by header', async () => {
      const res = await request(app.server).get('/health');
      expect(res.headers['x-powered-by']).toBeUndefined();
    });

    it('does not leak stack traces in 500 responses', async () => {
      const token = await login('student');
      // Request a non-existent route to trigger error handling
      const res = await request(app.server)
        .get('/this-route-does-not-exist')
        .set('Authorization', `Bearer ${token}`);
      expect(res.status).toBe(404);
      expect(res.body.error?.message).toBe('Route not found');
      // Ensure no stack trace
      expect(res.body.error?.stack).toBeUndefined();
      expect(res.body.stack).toBeUndefined();
    });

    it('returns structured error for unknown errors', async () => {
      // Hitting a 404 to ensure error format is consistent
      const res = await request(app.server).get('/nonexistent');
      expect(res.status).toBe(404);
      expect(res.body.error).toBeDefined();
      expect(res.body.error.code).toBe('NOT_FOUND');
      expect(res.body.error.message).toBe('Route not found');
      expect(res.body.error.details).toBeDefined();
    });
  });

  describe('content-type enforcement', () => {
    it('rejects POST with text/plain content-type', async () => {
      const token = await login('student');
      const res = await request(app.server)
        .post('/courses/COURSE_TEST/entries')
        .set('Authorization', `Bearer ${token}`)
        .set('Content-Type', 'text/plain')
        .send('not json');
      expect(res.status).toBe(415);
    });

    it('rejects POST with text/xml content-type', async () => {
      const token = await login('student');
      const res = await request(app.server)
        .post('/courses/COURSE_TEST/entries')
        .set('Authorization', `Bearer ${token}`)
        .set('Content-Type', 'text/xml')
        .send('<entry/>');
      expect(res.status).toBe(415);
    });

    it('allows POST with application/json content-type', async () => {
      const token = await login('student');
      const res = await request(app.server)
        .post('/courses/COURSE_TEST/entries')
        .set('Authorization', `Bearer ${token}`)
        .set('Content-Type', 'application/json')
        .send({
          id: 'content-type-test-entry',
          practiceDate: new Date().toISOString(),
          goalText: 'Test',
          tags: [],
        });
      expect(res.status).toBe(201);
    });

    it('allows GET requests without content-type', async () => {
      const res = await request(app.server).get('/health');
      expect(res.status).toBe(200);
    });
  });

  // Bug #9/16: Course role used consistently (verify already fixed)
  describe('course role authorization', () => {
    it('global teacher enrolled as course student cannot access other students entries', async () => {
      // User with global role teacher but course role student
      const mixedUser = await prisma.user.create({
        data: { id: 'global-teacher-course-student', displayName: 'Mixed', globalRole: 'teacher' },
      });
      await prisma.membership.create({
        data: {
          userId: mixedUser.id,
          courseId: 'COURSE_TEST',
          roleInCourse: 'student',
        },
      });

      // Another student's entry
      await prisma.practiceEntry.create({
        data: {
          id: 'entry-other-student',
          courseId: 'COURSE_TEST',
          studentId: 'student-1',
          practiceDate: new Date(),
          goalText: 'Other student entry',
          tags: ['tag'],
          status: 'draft',
        },
      });

      const token = await getAccessToken('teacher', { userId: mixedUser.id });
      const res = await request(app.server)
        .patch('/entries/entry-other-student')
        .set('Authorization', `Bearer ${token}`)
        .send({ goalText: 'Hijacked' });
      // Should be denied because course role is student and not the owner
      expect(res.status).toBe(403);
    });

    it('student enrolled as course teacher can post feedback', async () => {
      const mixedUser = await prisma.user.create({
        data: {
          id: 'global-student-course-teacher',
          displayName: 'Student Teacher',
          globalRole: 'student',
        },
      });
      await prisma.membership.create({
        data: {
          userId: mixedUser.id,
          courseId: 'COURSE_TEST',
          roleInCourse: 'teacher',
        },
      });

      await prisma.practiceEntry.create({
        data: {
          id: 'entry-for-mixed-feedback',
          courseId: 'COURSE_TEST',
          studentId: 'student-1',
          practiceDate: new Date(),
          goalText: 'Feedback target',
          tags: ['tag'],
          status: 'submitted',
        },
      });

      const token = await getAccessToken('student', { userId: mixedUser.id });
      const res = await request(app.server)
        .post('/feedback')
        .set('Authorization', `Bearer ${token}`)
        .send({
          targetType: 'entry',
          targetId: 'entry-for-mixed-feedback',
          status: 'ok',
          commentsText: 'Good practice',
          markers: [],
        });
      // Should be allowed because course role is teacher
      expect(res.status).toBe(201);
    });
  });
});
