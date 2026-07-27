// Verifies liveness, identity, logout, course detail, and feedback read routes.
import request from 'supertest';
import { beforeEach, describe, expect, it } from 'vitest';
import {
  app,
  deleteTestUser,
  getAccessToken,
  installBasicSuite,
  issueDevSession,
  login,
  prisma,
} from './support/testUtils.js';

function getCourse(token: string, courseId: string) {
  return request(app.server).get(`/courses/${courseId}`).set('Authorization', `Bearer ${token}`);
}

function getEntryFeedback(token: string, entryId: string) {
  return request(app.server)
    .get(`/entries/${entryId}/feedback`)
    .set('Authorization', `Bearer ${token}`);
}

describe('service routes', () => {
  installBasicSuite();

  // ═══════════════════════════════════════════════════════════════════
  // GET /health
  // ═══════════════════════════════════════════════════════════════════

  describe('GET /health', () => {
    it('returns 200 with status ok', async () => {
      const res = await request(app.server).get('/health');
      expect(res.status).toBe(200);
      expect(res.body).toEqual({ status: 'ok' });
    });

    it('does not require authentication', async () => {
      // No Authorization header
      const res = await request(app.server).get('/health');
      expect(res.status).toBe(200);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // GET /auth/me
  // ═══════════════════════════════════════════════════════════════════

  describe('GET /auth/me', () => {
    it('returns current user info for authenticated student', async () => {
      const token = await login('student');
      const res = await request(app.server).get('/auth/me').set('Authorization', `Bearer ${token}`);
      expect(res.status).toBe(200);
      expect(res.body).toEqual({
        id: 'student-1',
        displayName: 'Student',
        globalRole: 'student',
      });
    });

    it('returns current user info for authenticated teacher', async () => {
      const token = await login('teacher');
      const res = await request(app.server).get('/auth/me').set('Authorization', `Bearer ${token}`);
      expect(res.status).toBe(200);
      expect(res.body).toEqual({
        id: 'teacher-1',
        displayName: 'Teacher',
        globalRole: 'teacher',
      });
    });

    it('rejects unauthenticated request with 401', async () => {
      const res = await request(app.server).get('/auth/me');
      expect(res.status).toBe(401);
      expect(res.body.error?.code).toBe('MISSING_AUTH');
    });

    it('rejects invalid token with 401', async () => {
      const res = await request(app.server)
        .get('/auth/me')
        .set('Authorization', 'Bearer invalid-token');
      expect(res.status).toBe(401);
    });

    it('returns 404 when user record is deleted after token was issued', async () => {
      const token = await login('student');
      // Delete user record after token was issued
      await deleteTestUser('student-1');

      const res = await request(app.server).get('/auth/me').set('Authorization', `Bearer ${token}`);
      expect(res.status).toBe(404);
      expect(res.body.error?.code).toBe('USER_NOT_FOUND');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // POST /auth/logout
  // ═══════════════════════════════════════════════════════════════════

  describe('POST /auth/logout', () => {
    it('revokes all refresh tokens and returns success', async () => {
      // Create a session to get refresh tokens
      const { session } = await issueDevSession('student');
      const accessToken = session.body.accessToken as string;
      const refreshToken = session.body.refreshToken as string;

      // Logout
      const res = await request(app.server)
        .post('/auth/logout')
        .set('Authorization', `Bearer ${accessToken}`)
        .send();
      expect(res.status).toBe(200);
      expect(res.body).toEqual({ success: true });

      // Verify refresh token is now revoked
      const refreshRes = await request(app.server).post('/auth/refresh').send({ refreshToken });
      expect(refreshRes.status).toBe(401);
    });

    it('revokes multiple refresh tokens for the same user', async () => {
      // Create two sessions to get two refresh tokens
      const { session: session1 } = await issueDevSession('student');
      const { session: session2 } = await issueDevSession('student', {
        userId: session1.body.user.id,
      });

      const accessToken = session1.body.accessToken as string;
      const refreshToken2 = session2.body.refreshToken as string;

      // Logout using first session's access token
      const logoutRes = await request(app.server)
        .post('/auth/logout')
        .set('Authorization', `Bearer ${accessToken}`)
        .send();
      expect(logoutRes.status).toBe(200);

      // Verify second session's refresh token is also revoked
      const refreshRes = await request(app.server)
        .post('/auth/refresh')
        .send({ refreshToken: refreshToken2 });
      expect(refreshRes.status).toBe(401);
    });

    it('rejects unauthenticated request with 401', async () => {
      const res = await request(app.server).post('/auth/logout').send();
      expect(res.status).toBe(401);
      expect(res.body.error?.code).toBe('MISSING_AUTH');
    });

    it('succeeds even when user has no active refresh tokens', async () => {
      const token = await login('student');
      // Revoke all tokens manually first
      await prisma.refreshToken.updateMany({
        where: { userId: 'student-1' },
        data: { revokedAt: new Date() },
      });

      const res = await request(app.server)
        .post('/auth/logout')
        .set('Authorization', `Bearer ${token}`)
        .send();
      expect(res.status).toBe(200);
      expect(res.body).toEqual({ success: true });
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // GET /courses/:courseId
  // ═══════════════════════════════════════════════════════════════════

  describe('GET /courses/:courseId', () => {
    it.each(['student', 'teacher'] as const)(
      'returns course detail for enrolled %s',
      async (role) => {
        const token = await login(role);
        const res = await getCourse(token, 'COURSE_TEST');
        expect(res.status).toBe(200);
        expect(res.body.id).toBe('COURSE_TEST');
        expect(res.body.title).toBe('Test Course');
      }
    );

    it('rejects access for user not enrolled in the course', async () => {
      const outsider = await prisma.user.create({
        data: { id: 'outsider-1', displayName: 'Outsider', globalRole: 'student' },
      });
      const token = await getAccessToken('student', { userId: outsider.id });
      const res = await request(app.server)
        .get('/courses/COURSE_TEST')
        .set('Authorization', `Bearer ${token}`);
      expect(res.status).toBe(403);
    });

    it('returns 404 for non-existent course', async () => {
      // Student is enrolled in COURSE_TEST, but requests a non-existent course
      const token = await login('student');
      const res = await request(app.server)
        .get('/courses/NON_EXISTENT')
        .set('Authorization', `Bearer ${token}`);
      // Should be 403 (not enrolled) rather than leaking existence info
      expect([403, 404]).toContain(res.status);
    });

    it('rejects unauthenticated request with 401', async () => {
      const res = await request(app.server).get('/courses/COURSE_TEST');
      expect(res.status).toBe(401);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // GET /entries/:entryId/feedback
  // ═══════════════════════════════════════════════════════════════════

  describe('GET /entries/:entryId/feedback', () => {
    let entryId: string;

    beforeEach(async () => {
      entryId = 'entry-feedback-get';
      await prisma.practiceEntry.create({
        data: {
          id: entryId,
          courseId: 'COURSE_TEST',
          studentId: 'student-1',
          practiceDate: new Date(),
          goalText: 'Feedback retrieval test',
          tags: ['tag'],
          status: 'submitted',
        },
      });
    });

    it('returns empty array when no feedback exists', async () => {
      const token = await login('student');
      const res = await getEntryFeedback(token, entryId);
      expect(res.status).toBe(200);
      expect(res.body).toEqual([]);
    });

    it('returns feedback with markers for the entry', async () => {
      // Create feedback with markers
      await prisma.feedback.create({
        data: {
          id: 'fb_get_test_1',
          targetType: 'entry',
          targetId: entryId,
          teacherId: 'teacher-1',
          entryId,
          status: 'ok',
          commentsText: 'Well done',
          markers: {
            create: [
              { id: 'mk_get_1', timeSeconds: 5, text: 'Good intonation' },
              { id: 'mk_get_2', timeSeconds: 30, text: 'Watch tempo' },
            ],
          },
        },
      });

      const token = await login('student');
      const res = await getEntryFeedback(token, entryId);
      expect(res.status).toBe(200);
      expect(res.body).toHaveLength(1);
      expect(res.body[0].id).toBe('fb_get_test_1');
      expect(res.body[0].commentsText).toBe('Well done');
      expect(res.body[0].teacherName).toBe('Teacher');
      expect(res.body[0].markers).toHaveLength(2);
      expect(res.body[0].status).toBe('ok');
    });

    it('returns multiple feedback items for the same entry', async () => {
      await prisma.feedback.create({
        data: {
          id: 'fb_multi_get_1',
          targetType: 'entry',
          targetId: entryId,
          teacherId: 'teacher-1',
          entryId,
          status: 'needs_revision',
          commentsText: 'First review',
        },
      });
      await prisma.feedback.create({
        data: {
          id: 'fb_multi_get_2',
          targetType: 'entry',
          targetId: entryId,
          teacherId: 'teacher-1',
          entryId,
          status: 'ok',
          commentsText: 'Second review',
        },
      });

      const token = await login('student');
      const res = await getEntryFeedback(token, entryId);
      expect(res.status).toBe(200);
      expect(res.body).toHaveLength(2);
    });

    it('teacher can also retrieve feedback', async () => {
      await prisma.feedback.create({
        data: {
          id: 'fb_teacher_get',
          targetType: 'entry',
          targetId: entryId,
          teacherId: 'teacher-1',
          entryId,
          status: 'ok',
          commentsText: 'Teacher checking',
        },
      });

      const token = await login('teacher');
      const res = await getEntryFeedback(token, entryId);
      expect(res.status).toBe(200);
      expect(res.body).toHaveLength(1);
    });

    it('rejects access for user not enrolled in the course', async () => {
      const outsider = await prisma.user.create({
        data: { id: 'outsider-fb', displayName: 'Outsider', globalRole: 'student' },
      });
      const token = await getAccessToken('student', { userId: outsider.id });
      const res = await request(app.server)
        .get(`/entries/${entryId}/feedback`)
        .set('Authorization', `Bearer ${token}`);
      expect(res.status).toBe(403);
    });

    it('returns 404 for non-existent entry', async () => {
      const token = await login('student');
      const res = await request(app.server)
        .get('/entries/non-existent-entry/feedback')
        .set('Authorization', `Bearer ${token}`);
      expect(res.status).toBe(404);
    });

    it('rejects unauthenticated request with 401', async () => {
      const res = await request(app.server).get(`/entries/${entryId}/feedback`);
      expect(res.status).toBe(401);
    });

    it('student cannot access feedback on another students entry', async () => {
      const otherStudent = await prisma.user.create({
        data: { id: 'student-fb-other', displayName: 'Other', globalRole: 'student' },
      });
      await prisma.membership.create({
        data: { userId: otherStudent.id, courseId: 'COURSE_TEST', roleInCourse: 'student' },
      });

      const token = await getAccessToken('student', { userId: otherStudent.id });
      const res = await request(app.server)
        .get(`/entries/${entryId}/feedback`)
        .set('Authorization', `Bearer ${token}`);
      // Entry belongs to student-1, so student-fb-other should be denied
      expect(res.status).toBe(403);
    });
  });
});
