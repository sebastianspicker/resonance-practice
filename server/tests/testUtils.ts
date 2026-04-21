import request from 'supertest';
import { PrismaClient } from '@prisma/client';
import { buildServer } from '../src/server.js';
import { S3Client } from '@aws-sdk/client-s3';
import { mockClient } from 'aws-sdk-client-mock';
import { createS3Client } from '../src/storage.js';

export const prisma = new PrismaClient();
export const s3Client = createS3Client();
export const s3Mock = mockClient(S3Client);
export const app = buildServer(prisma, s3Client);

export type TestRole = 'student' | 'teacher';

function assertTestDatabase() {
  const dbUrl = process.env.DATABASE_URL;
  if (!dbUrl || !dbUrl.toLowerCase().includes('test')) {
    throw new Error(
      `Refusing destructive test setup against non-test database: ${dbUrl ?? '<unset>'}`
    );
  }
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
    'TRUNCATE "Marker", "Feedback", "Artifact", "PracticeEntry", "Membership", "Course", "User", "RefreshToken" CASCADE;'
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
