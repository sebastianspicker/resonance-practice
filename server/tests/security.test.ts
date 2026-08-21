// Compact HTTP security and data-integrity regressions backed by the test database.
import request from 'supertest';
import { describe, expect, it } from 'vitest';
import {
  app,
  getAccessToken,
  installBasicSuite,
  issueDevSession,
  login,
  prisma,
} from './support/testUtils.js';

describe('HTTP security boundaries', () => {
  installBasicSuite();

  it('serves refresh in dev mode and rejects hostile client identifiers', async () => {
    const { session } = await issueDevSession('student');
    const refresh = await request(app.server)
      .post('/auth/refresh')
      .send({ refreshToken: session.body.refreshToken });
    expect(refresh.status).toBe(200);
    expect(refresh.body.refreshToken?.split('.')).toHaveLength(3);

    const token = await login('student');
    const invalid = await request(app.server)
      .post('/courses/COURSE_TEST/entries')
      .set('Authorization', `Bearer ${token}`)
      .send({
        id: '../../../etc/passwd',
        practiceDate: new Date().toISOString(),
        goalText: 'invalid',
        tags: [],
      });
    expect(invalid.status).toBe(400);
    expect(invalid.body.error?.code).toBe('VALIDATION_ERROR');
  });

  it('treats an exact duplicate write as idempotent', async () => {
    const token = await login('student');
    const payload = {
      id: 'duplicate-entry-id',
      practiceDate: new Date().toISOString(),
      goalText: 'same request',
      tags: [],
    };
    const first = await request(app.server)
      .post('/courses/COURSE_TEST/entries')
      .set('Authorization', `Bearer ${token}`)
      .send(payload);
    const second = await request(app.server)
      .post('/courses/COURSE_TEST/entries')
      .set('Authorization', `Bearer ${token}`)
      .send(payload);
    expect([first.status, second.status]).toEqual([201, 200]);
    expect(second.body.id).toBe(payload.id);
  });

  it('refuses child mutations after a parent entry is deleted', async () => {
    const entry = await prisma.practiceEntry.create({
      data: {
        id: 'deleted-entry',
        courseId: 'COURSE_TEST',
        studentId: 'student-1',
        practiceDate: new Date(),
        goalText: 'deleted',
        tags: [],
        status: 'submitted',
        deletedAt: new Date(),
      },
    });
    const artifact = await prisma.artifact.create({
      data: {
        id: 'deleted-parent-artifact',
        entryId: entry.id,
        type: 'audio',
        durationSeconds: 1,
        uploadState: 'uploaded',
      },
    });
    const student = await login('student');
    const teacher = await login('teacher');
    const create = await request(app.server)
      .post('/api/v1/artifact-sessions')
      .set('Authorization', `Bearer ${student}`)
      .send({
        operationId: 'deleted-parent-operation',
        entryId: entry.id,
        artifactId: 'new-artifact',
        type: 'audio',
        durationSeconds: 1,
        sizeBytes: 1,
        baseVersion: 1,
      });
    const feedback = await request(app.server)
      .post('/feedback')
      .set('Authorization', `Bearer ${teacher}`)
      .send({
        targetType: 'artifact',
        targetId: artifact.id,
        status: 'ok',
        commentsText: 'blocked',
        markers: [],
      });
    expect([create.status, feedback.status]).toEqual([410, 410]);
  });

  it('sets hardening headers and returns structured errors without stack traces', async () => {
    const health = await request(app.server).get('/health');
    expect(health.headers).toMatchObject({
      'x-content-type-options': 'nosniff',
      'x-frame-options': 'DENY',
      'referrer-policy': 'no-referrer',
    });
    expect(health.headers['content-security-policy']).toContain("frame-ancestors 'none'");
    expect(health.headers['x-powered-by']).toBeUndefined();

    const missing = await request(app.server).get('/not-a-route');
    expect(missing.body.error).toMatchObject({ code: 'NOT_FOUND', message: 'Route not found' });
    expect(JSON.stringify(missing.body)).not.toContain('stack');
  });

  it('rejects non-JSON mutation bodies', async () => {
    const token = await login('student');
    const response = await request(app.server)
      .post('/courses/COURSE_TEST/entries')
      .set('Authorization', `Bearer ${token}`)
      .set('Content-Type', 'text/plain')
      .send('not json');
    expect(response.status).toBe(415);
  });

  it('uses course role rather than global role for authorization', async () => {
    const mixed = await prisma.user.create({
      data: { id: 'global-teacher-course-student', displayName: 'Mixed', globalRole: 'teacher' },
    });
    await prisma.membership.create({
      data: { userId: mixed.id, courseId: 'COURSE_TEST', roleInCourse: 'student' },
    });
    await prisma.practiceEntry.create({
      data: {
        id: 'other-student-entry',
        courseId: 'COURSE_TEST',
        studentId: 'student-1',
        practiceDate: new Date(),
        goalText: 'protected',
        tags: [],
      },
    });
    const token = await getAccessToken('teacher', { userId: mixed.id });
    const response = await request(app.server)
      .patch('/entries/other-student-entry')
      .set('Authorization', `Bearer ${token}`)
      .send({ goalText: 'hijacked' });
    expect(response.status).toBe(403);
  });
});
