// Provides shared authenticated fixtures backed by real Prisma and a mocked S3 client.
import request from 'supertest';
import { Prisma, PrismaClient } from '@prisma/client';
import { buildServer } from '../../src/server.js';
import { S3Client } from '@aws-sdk/client-s3';
import { mockClient } from 'aws-sdk-client-mock';
import { afterAll, beforeAll, beforeEach, expect } from 'vitest';
import { createS3Client } from '../../src/storage.js';
import { assertTestDatabaseUrl } from './databaseSafety.js';

export const prisma = new PrismaClient();
const s3Client = createS3Client();
export const s3Mock = mockClient(S3Client);
export const app = buildServer(prisma, s3Client);

export type TestRole = 'student' | 'teacher';

function assertTestDatabase() {
  assertTestDatabaseUrl(process.env.DATABASE_URL);
}

export async function getAccessToken(
  role: TestRole,
  options?: { userId?: string }
): Promise<string> {
  const body = options?.userId ? { userId: options.userId, role } : { role };
  const issue = await request(app.server).post('/dev/issue').send(body);
  const session = await request(app.server)
    .post('/auth/session')
    .send({ code: issue.body.code, redirectUri: 'resonance://auth-callback' });
  return session.body.accessToken as string;
}

export async function issueDevSession(
  role: TestRole,
  options: { userId?: string; includeRedirectUri?: boolean } = {}
) {
  const issueBody = options.userId ? { userId: options.userId, role } : { role };
  const issue = await request(app.server).post('/dev/issue').send(issueBody);
  const sessionBody: Record<string, unknown> = { code: issue.body.code };
  if (options.includeRedirectUri !== false) {
    sessionBody.redirectUri = 'resonance://auth-callback';
  }
  const session = await request(app.server).post('/auth/session').send(sessionBody);
  return { issue, session };
}

export function expectDevSessionIssued(
  issue: { status: number },
  session: { status: number; body: { accessToken?: unknown } }
) {
  expect(issue.status).toBe(200);
  expect(session.status).toBe(201);
  expect(typeof session.body.accessToken).toBe('string');
}

export async function deleteTestUser(userId: string) {
  await prisma.membership.deleteMany({ where: { userId } });
  await prisma.refreshToken.deleteMany({ where: { userId } });
  await prisma.user.delete({ where: { id: userId } });
}

export function login(role: TestRole) {
  const userId = role === 'student' ? 'student-1' : 'teacher-1';
  return getAccessToken(role, { userId });
}

export function getReviewQueue(token: string, path = '/courses/COURSE_TEST/review-queue') {
  return request(app.server).get(path).set('Authorization', `Bearer ${token}`);
}

export function postFeedback(token: string, body: Record<string, unknown>) {
  return request(app.server).post('/feedback').set('Authorization', `Bearer ${token}`).send(body);
}

export function deleteEntry(token: string, entryId: string) {
  return request(app.server).delete(`/entries/${entryId}`).set('Authorization', `Bearer ${token}`);
}

export function createArtifactSession(token: string, body: Record<string, unknown>) {
  return request(app.server)
    .post('/api/v1/artifact-sessions')
    .set('Authorization', `Bearer ${token}`)
    .send(body);
}

type TestEntryInput = Omit<Prisma.PracticeEntryUncheckedCreateInput, 'courseId' | 'studentId'> & {
  courseId?: string;
  studentId?: string;
};

export function createTestEntry({
  courseId = 'COURSE_TEST',
  studentId = 'student-1',
  ...data
}: TestEntryInput) {
  return prisma.practiceEntry.create({ data: { courseId, studentId, ...data } });
}

export function createTestArtifact(data: Prisma.ArtifactUncheckedCreateInput) {
  return prisma.artifact.create({ data });
}

export function createTestFeedback(data: Prisma.FeedbackUncheckedCreateInput) {
  return prisma.feedback.create({ data });
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
