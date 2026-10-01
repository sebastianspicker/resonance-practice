// Provides shared authenticated fixtures backed by real Prisma and a mocked S3 client.
import request from 'supertest';
import { PrismaClient } from '@prisma/client';
import { buildServer } from '../../src/server.js';
import { S3Client } from '@aws-sdk/client-s3';
import { mockClient } from 'aws-sdk-client-mock';
import { afterAll, beforeAll, beforeEach } from 'vitest';
import { createS3Client } from '../../src/platform/storage/s3.js';
import { s256CodeChallenge } from '../../src/modules/identity/application/auth.js';
import { assertTestDatabaseUrl } from './databaseSafety.js';

export const prisma = new PrismaClient();
const s3Client = createS3Client();
export const s3Mock = mockClient(S3Client);
export const app = buildServer(prisma, s3Client);

export type TestRole = 'student' | 'teacher';
const testCodeVerifier = 'a'.repeat(43);

function assertTestDatabase() {
  assertTestDatabaseUrl(process.env.DATABASE_URL);
}

export async function getAccessToken(
  role: TestRole,
  options?: { userId?: string }
): Promise<string> {
  const body = {
    ...(options?.userId ? { userId: options.userId, role } : { role }),
    app_code_challenge: s256CodeChallenge(testCodeVerifier),
  };
  const issue = await request(app.server).post('/dev/issue').send(body);
  const session = await request(app.server).post('/auth/session').send({
    code: issue.body.code,
    codeVerifier: testCodeVerifier,
    redirectUri: 'resonance://auth-callback',
  });
  return session.body.accessToken as string;
}

export function login(role: TestRole) {
  const userId = role === 'student' ? 'student-1' : 'teacher-1';
  return getAccessToken(role, { userId });
}

export function installBasicSuite(options: { resetS3?: boolean } = {}) {
  beforeAll(setupApp);
  afterAll(teardownApp);
  beforeEach(async () => {
    if (options.resetS3) s3Mock.reset();
    await resetDb();
    await seedBasic();
  });
}

export async function setupApp() {
  await prisma.$connect();
  await app.ready();
}

export async function teardownApp() {
  await app.close();
  await prisma.$disconnect();
}

export async function resetDb() {
  assertTestDatabase();
  await prisma.$executeRawUnsafe(
    'TRUNCATE "ArtifactUploadSession", "SyncReceipt", "AuthFlowToken", "StorageDeletionJob", "DeletedEntryTombstone", "CaptureMarker", "Marker", "Feedback", "Artifact", "PracticeEntry", "Membership", "Course", "User", "RefreshToken" CASCADE;'
  );
}

export async function seedBasic() {
  const student = await prisma.user.create({
    data: { id: 'student-1', displayName: 'Student', globalRole: 'student' },
  });
  const teacher = await prisma.user.create({
    data: { id: 'teacher-1', displayName: 'Teacher', globalRole: 'teacher' },
  });
  const course = await prisma.course.create({
    data: { id: 'COURSE_TEST', title: 'Test Course' },
  });
  await prisma.membership.create({
    data: { userId: student.id, courseId: course.id, roleInCourse: 'student' },
  });
  await prisma.membership.create({
    data: { userId: teacher.id, courseId: course.id, roleInCourse: 'teacher' },
  });
  return { student, teacher, course };
}
