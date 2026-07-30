// Verifies login, refresh, logout, and development-auth behavior through the HTTP API.
import request from 'supertest';
import { describe, expect, it } from 'vitest';
import {
  app,
  expectDevSessionIssued,
  getAccessToken,
  installBasicSuite,
  issueDevSession,
  prisma,
} from './support/testUtils.js';

describe('auth', () => {
  installBasicSuite();

  it('exchanges dev code for tokens', async () => {
    const { issue, session } = await issueDevSession('student');
    expectDevSessionIssued(issue, session);
    expect(session.body.accessToken.split('.')).toHaveLength(3);
    expect(typeof session.body.refreshToken).toBe('string');
    expect(session.body.refreshToken.split('.')).toHaveLength(3);
  });

  it('should return courses with id and title when authenticated as student', async () => {
    const token = await getAccessToken('student');
    const res = await request(app.server).get('/courses').set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(200);
    expect(Array.isArray(res.body)).toBe(true);
    expect(res.body.length).toBeGreaterThanOrEqual(1);
    expect(res.body[0]).toHaveProperty('id');
    expect(res.body[0]).toHaveProperty('title');
  });

  it('should return 401 with MISSING_AUTH when no token is provided', async () => {
    const res = await request(app.server).get('/courses');
    expect(res.status).toBe(401);
    expect(res.body.error?.code).toBe('MISSING_AUTH');
  });

  it('contains refresh-token replay to its lineage without revoking another session', async () => {
    const { session } = await issueDevSession('student');
    const { session: independentSession } = await issueDevSession('student', {
      userId: session.body.user.id,
    });

    const refreshToken = session.body.refreshToken as string;
    const refreshed = await request(app.server).post('/auth/refresh').send({ refreshToken });

    expect(refreshed.status).toBe(200);
    expect(typeof refreshed.body.refreshToken).toBe('string');
    expect(refreshed.body.refreshToken).not.toBe(refreshToken);

    const reuse = await request(app.server).post('/auth/refresh').send({ refreshToken });
    expect(reuse.status).toBe(401);
    expect(reuse.body.error?.code).toBe('REFRESH_ALREADY_USED');

    const stolenReplacement = await request(app.server)
      .post('/auth/refresh')
      .send({ refreshToken: refreshed.body.refreshToken });
    expect(stolenReplacement.status).toBe(401);
    expect(stolenReplacement.body.error?.code).toBe('REFRESH_ALREADY_USED');

    const independentRefresh = await request(app.server)
      .post('/auth/refresh')
      .send({ refreshToken: independentSession.body.refreshToken });
    expect(independentRefresh.status).toBe(200);
  });

  it('rejects invalid refresh tokens', async () => {
    const res = await request(app.server)
      .post('/auth/refresh')
      .send({ refreshToken: 'not-a-token' });
    expect(res.status).toBe(401);
    expect(res.body.error?.code).toBe('INVALID_REFRESH');
  });

  it('revokes a refresh-token family when logging out with refreshToken body only', async () => {
    const { session: session1 } = await issueDevSession('student');
    const { session: session2 } = await issueDevSession('student', {
      userId: session1.body.user.id,
    });

    const logout = await request(app.server)
      .post('/auth/logout')
      .send({ refreshToken: session1.body.refreshToken });

    expect(logout.status).toBe(200);
    expect(logout.body).toEqual({ success: true });

    const activeTokens = await prisma.refreshToken.count({
      where: { userId: session1.body.user.id, revokedAt: null },
    });
    expect(activeTokens).toBe(0);

    const reuseSecondToken = await request(app.server)
      .post('/auth/refresh')
      .send({ refreshToken: session2.body.refreshToken });
    expect(reuseSecondToken.status).toBe(401);
  });

  it('leaves no live replacement token when logout races refresh rotation', async () => {
    const { session } = await issueDevSession('student');
    const refreshToken = session.body.refreshToken as string;

    const [refresh, logout] = await Promise.all([
      request(app.server).post('/auth/refresh').send({ refreshToken }),
      request(app.server).post('/auth/logout').send({ refreshToken }),
    ]);

    expect([200, 401]).toContain(refresh.status);
    expect(logout.status).toBe(200);
    await expect(
      prisma.refreshToken.count({
        where: { userId: session.body.user.id, revokedAt: null },
      })
    ).resolves.toBe(0);
  });
});
