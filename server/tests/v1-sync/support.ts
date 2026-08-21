import request from 'supertest';
import { afterAll, beforeAll, beforeEach } from 'vitest';
import {
  app,
  getAccessToken,
  prisma,
  resetDb,
  seedBasic,
  setupApp,
  teardownApp,
} from '../support/testUtils.js';

export function installV1SyncSuite() {
  let studentToken = '';
  let teacherToken = '';

  beforeAll(async () => {
    await setupApp();
  });
  beforeEach(async () => {
    await resetDb();
    await seedBasic();
    studentToken = await getAccessToken('student', { userId: 'student-1' });
    teacherToken = await getAccessToken('teacher', { userId: 'teacher-1' });
  });
  afterAll(teardownApp);

  return {
    get studentToken() {
      return studentToken;
    },
    get teacherToken() {
      return teacherToken;
    },
  };
}

export const createEntryCommand = (operationId = 'v1-create-1') => ({
  operationId,
  entityId: 'v1-entry-1',
  kind: 'createEntry',
  payload: {
    courseId: 'COURSE_TEST',
    kind: 'practice',
    practiceDate: '2026-07-16',
    goalText: 'Keep a steady pulse',
    tags: [],
  },
});

export const executeSyncCommands = (token: string, commands: Array<Record<string, unknown>>) =>
  request(app.server)
    .post('/api/v1/sync/commands')
    .set('authorization', `Bearer ${token}`)
    .send({ commands });

export async function enrollCourseMember(
  role: 'student' | 'teacher',
  userId: string,
  displayName: string
) {
  await prisma.user.create({
    data: { id: userId, displayName, globalRole: role },
  });
  await prisma.membership.create({
    data: { userId, courseId: 'COURSE_TEST', roleInCourse: role },
  });
  return getAccessToken(role, { userId });
}
