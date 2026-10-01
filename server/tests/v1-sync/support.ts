import type { Prisma } from '@prisma/client';
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

let freshMemberSequence = 0;

/** Enroll a uniquely named member so each test gets its own per-user sync admission window. */
export async function enrollFreshMember(role: 'student' | 'teacher') {
  freshMemberSequence += 1;
  const userId = `${role}-fresh-${freshMemberSequence}`;
  const token = await enrollCourseMember(role, userId, `Fresh ${role} ${freshMemberSequence}`);
  return { userId, token };
}

export const syncCommand = (
  kind: string,
  entityId: string,
  operationId: string,
  baseVersion: number | undefined,
  payload: Record<string, unknown> = {}
) => ({
  operationId,
  entityId,
  kind,
  ...(baseVersion === undefined ? {} : { baseVersion }),
  payload,
});

export const createEntryWith = (
  entityId: string,
  operationId: string,
  overrides: Record<string, unknown> = {}
) =>
  syncCommand('createEntry', entityId, operationId, undefined, {
    ...createEntryCommand().payload,
    ...overrides,
  });

export const teachingLessonFields = {
  kind: 'teaching_lesson',
  consentConfirmedAt: '2026-07-16T10:00:00.000Z',
  consentScope: 'private_course_review',
  captureProfile: 'room_overview',
};

export function seedEntry(
  id: string,
  studentId: string,
  overrides: Partial<Prisma.PracticeEntryUncheckedCreateInput> = {}
) {
  return prisma.practiceEntry.create({
    data: {
      id,
      courseId: 'COURSE_TEST',
      studentId,
      practiceDate: new Date('2026-07-16T00:00:00.000Z'),
      goalText: 'Seeded goal',
      tags: [],
      ...overrides,
    },
  });
}

export function seedArtifact(
  id: string,
  entryId: string,
  overrides: Partial<Prisma.ArtifactUncheckedCreateInput> = {}
) {
  return prisma.artifact.create({
    data: {
      id,
      entryId,
      type: 'audio',
      durationSeconds: 30,
      uploadState: 'uploaded',
      storageKey: `artifacts/final/${entryId}/${id}-key`,
      expectedSizeBytes: 128,
      ...overrides,
    },
  });
}

export const teachingLessonSeed = {
  kind: 'teaching_lesson',
  consentConfirmedAt: new Date('2026-07-16T10:00:00.000Z'),
  consentScope: 'private_course_review',
  captureProfile: 'room_overview',
} as const;
