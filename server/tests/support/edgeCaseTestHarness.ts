import request from 'supertest';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import {
  app,
  getAccessToken,
  prisma,
  resetDb,
  s3Mock,
  seedBasic,
  setupApp,
  teardownApp,
} from './testUtils.js';

export { app, describe, expect, it, prisma, request };

export function login(role: 'student' | 'teacher') {
  const userId = role === 'student' ? 'student-1' : 'teacher-1';
  return getAccessToken(role, { userId });
}

export function installEdgeCaseSuite() {
  beforeAll(async () => {
    await setupApp();
  });

  afterAll(async () => {
    await teardownApp();
  });

  beforeEach(async () => {
    s3Mock.reset();
    await resetDb();
    await seedBasic();
  });
}
