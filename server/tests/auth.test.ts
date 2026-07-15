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

describe('auth', () => {
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

  it('exchanges dev code for tokens', async () => {
    const issue = await request(app.server).post('/dev/issue').send({ role: 'student' });
    expect(issue.status).toBe(200);

    const session = await request(app.server).post('/auth/session').send({
      code: issue.body.code,
      redirectUri: 'resonance://auth-callback',
    });

    expect(session.status).toBe(201);
    expect(typeof session.body.accessToken).toBe('string');
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
    const issue = await request(app.server).post('/dev/issue').send({ role: 'student' });
    const session = await request(app.server).post('/auth/session').send({
      code: issue.body.code,
      redirectUri: 'resonance://auth-callback',
    });
    const independentIssue = await request(app.server)
      .post('/dev/issue')
      .send({ role: 'student', userId: session.body.user.id });
    const independentSession = await request(app.server).post('/auth/session').send({
      code: independentIssue.body.code,
      redirectUri: 'resonance://auth-callback',
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
    const issue1 = await request(app.server).post('/dev/issue').send({ role: 'student' });
    const session1 = await request(app.server).post('/auth/session').send({
      code: issue1.body.code,
      redirectUri: 'resonance://auth-callback',
    });

    const issue2 = await request(app.server)
      .post('/dev/issue')
      .send({ role: 'student', userId: session1.body.user.id });
    const session2 = await request(app.server).post('/auth/session').send({
      code: issue2.body.code,
      redirectUri: 'resonance://auth-callback',
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
    const issue = await request(app.server).post('/dev/issue').send({ role: 'student' });
    const session = await request(app.server).post('/auth/session').send({
      code: issue.body.code,
      redirectUri: 'resonance://auth-callback',
    });
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
