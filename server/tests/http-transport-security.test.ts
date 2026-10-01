/** HTTP-level transport hardening, structured errors, hostile identifiers, and course-role authorization. */
import request from 'supertest';
import { describe, expect, it } from 'vitest';
import { app, getAccessToken, installBasicSuite, login, prisma } from './support/testUtils.js';
import { createSession, sessionPayload } from './support/artifactUpload.js';
import { seedEntry } from './v1-sync/support.js';

const malformedIds = [
  ['path traversal', '../../../etc/passwd'],
  ['special characters', 'entry$<script>'],
  ['whitespace', 'entry id'],
] as const;
const hostileIds = [...malformedIds, ['overlong', 'a'.repeat(129)]] as const;

describe('HTTP transport security', () => {
  installBasicSuite();

  it('sets hardening headers, drops x-powered-by, and echoes the request ID', async () => {
    const response = await request(app.server).get('/health').set('x-request-id', 'req-hardening');
    expect(response.status).toBe(200);
    expect(response.headers).toMatchObject({
      'x-content-type-options': 'nosniff',
      'x-frame-options': 'DENY',
      'referrer-policy': 'no-referrer',
      'x-request-id': 'req-hardening',
    });
    expect(response.headers['content-security-policy']).toContain("frame-ancestors 'none'");
    expect(response.headers['x-powered-by']).toBeUndefined();
  });

  it('returns a structured 404 for unknown routes without a stack trace', async () => {
    const response = await request(app.server).get('/not-a-route').set('x-request-id', 'req-404');
    expect(response.status).toBe(404);
    expect(response.body).toEqual({
      error: { code: 'NOT_FOUND', message: 'Route not found', details: {}, requestId: 'req-404' },
    });
    expect(response.text).not.toContain('stack');
  });

  it('rejects non-JSON mutation bodies with 415', async () => {
    const token = await login('student');
    for (const contentType of ['text/plain', 'application/xml']) {
      const response = await request(app.server)
        .post('/api/v1/sync/commands')
        .set('authorization', `Bearer ${token}`)
        .set('content-type', contentType)
        .send('not json');
      expect(response.status).toBe(415);
      expect(response.body.error).toMatchObject({ code: 'VALIDATION_ERROR' });
    }
  });

  it('rejects an overlong route param at the router before any handler runs', async () => {
    // Fastify's 100-character maxParamLength answers 414 before ID validation sees the value.
    const token = await login('student');
    const response = await request(app.server)
      .get(`/api/v1/entries/${'a'.repeat(129)}`)
      .set('authorization', `Bearer ${token}`);
    expect(response.status).toBe(414);
    expect(response.text).not.toContain('stack');
  });

  it('rejects malformed JSON with 400', async () => {
    const token = await login('student');
    const response = await request(app.server)
      .post('/api/v1/sync/commands')
      .set('authorization', `Bearer ${token}`)
      .set('content-type', 'application/json')
      .send('{"commands": [');
    expect(response.status).toBe(400);
    expect(response.body.error).toMatchObject({
      code: 'VALIDATION_ERROR',
      message: 'Invalid JSON in request body',
    });
    expect(response.text).not.toContain('stack');
  });

  it.each(malformedIds)('rejects a %s identifier in route params', async (_name, id) => {
    const token = await login('student');
    const encoded = encodeURIComponent(id);
    for (const path of [`/api/v1/entries/${encoded}`, `/api/v1/courses/${encoded}/entries`]) {
      const response = await request(app.server).get(path).set('authorization', `Bearer ${token}`);
      expect(response.status).toBe(400);
      expect(response.body.error).toMatchObject({ code: 'VALIDATION_ERROR' });
    }
  });

  it.each(hostileIds)('rejects a %s identifier as a sync entityId', async (_name, id) => {
    const token = await login('student');
    const response = await request(app.server)
      .post('/api/v1/sync/commands')
      .set('authorization', `Bearer ${token}`)
      .send({
        commands: [
          {
            operationId: 'hostile-operation',
            entityId: id,
            kind: 'createEntry',
            payload: {
              courseId: 'COURSE_TEST',
              kind: 'practice',
              practiceDate: '2026-07-16',
              goalText: 'hostile',
              tags: [],
            },
          },
        ],
      });
    expect(response.status).toBe(400);
    expect(response.body.error).toMatchObject({ code: 'VALIDATION_ERROR' });
    expect(await prisma.practiceEntry.count()).toBe(0);
  });

  it('refuses artifact-session creation under a deleted parent entry', async () => {
    await seedEntry('deleted-entry', 'student-1', { deletedAt: new Date() });
    const response = await createSession(
      await login('student'),
      sessionPayload({ entryId: 'deleted-entry', operationId: 'deleted-parent-operation' })
    );
    expect(response.status).toBe(410);
    expect(response.body.error).toMatchObject({ code: 'ENTRY_DELETED' });
    expect(await prisma.artifact.count()).toBe(0);
  });

  describe('course role, not global role, authorizes entry access', () => {
    async function enrollMixedRoleUser(
      id: string,
      globalRole: 'student' | 'teacher',
      roleInCourse: 'student' | 'teacher'
    ) {
      await prisma.user.create({ data: { id, displayName: id, globalRole } });
      await prisma.membership.create({
        data: { userId: id, courseId: 'COURSE_TEST', roleInCourse },
      });
      return getAccessToken(globalRole, { userId: id });
    }

    it("denies a global teacher enrolled as a course student another student's draft", async () => {
      const token = await enrollMixedRoleUser(
        'global-teacher-course-student',
        'teacher',
        'student'
      );
      await seedEntry('other-student-draft', 'student-1', { goalText: 'protected' });

      const read = await request(app.server)
        .get('/api/v1/entries/other-student-draft')
        .set('authorization', `Bearer ${token}`);
      expect(read.status).toBe(403);
      expect(read.body.error).toMatchObject({ code: 'ENTRY_ACCESS_DENIED' });

      const update = await request(app.server)
        .post('/api/v1/sync/commands')
        .set('authorization', `Bearer ${token}`)
        .send({
          commands: [
            {
              operationId: 'hijack-operation',
              entityId: 'other-student-draft',
              kind: 'updateEntry',
              baseVersion: 1,
              payload: { goalText: 'hijacked' },
            },
          ],
        });
      expect(update.status).toBe(200);
      expect(update.body.results[0]).toMatchObject({ status: 'rejected', code: 'STUDENT_ONLY' });
      const row = await prisma.practiceEntry.findUniqueOrThrow({
        where: { id: 'other-student-draft' },
      });
      expect(row).toMatchObject({ goalText: 'protected', version: 1 });
    });

    it('lets a global student enrolled as a course teacher see submitted entries only', async () => {
      const token = await enrollMixedRoleUser(
        'global-student-course-teacher',
        'student',
        'teacher'
      );
      await seedEntry('submitted-entry', 'student-1', { status: 'submitted' });
      await seedEntry('draft-entry', 'student-1');

      const submitted = await request(app.server)
        .get('/api/v1/entries/submitted-entry')
        .set('authorization', `Bearer ${token}`);
      expect(submitted.status).toBe(200);
      expect(submitted.body).toMatchObject({ id: 'submitted-entry', status: 'submitted' });

      const list = await request(app.server)
        .get('/api/v1/courses/COURSE_TEST/entries')
        .set('authorization', `Bearer ${token}`);
      expect(list.status).toBe(200);
      expect(list.body.items.map((item: { id: string }) => item.id)).toEqual(['submitted-entry']);

      const draft = await request(app.server)
        .get('/api/v1/entries/draft-entry')
        .set('authorization', `Bearer ${token}`);
      expect(draft.status).toBe(403);
      expect(draft.body.error).toMatchObject({ code: 'ENTRY_ACCESS_DENIED' });
    });
  });
});
