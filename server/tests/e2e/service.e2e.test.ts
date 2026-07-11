import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { once } from 'node:events';
import { request as httpRequest } from 'node:http';
import net from 'node:net';
import { setTimeout as delay } from 'node:timers/promises';
import { PrismaClient } from '@prisma/client';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';

const prisma = new PrismaClient();
const serverLogs: string[] = [];

let serverProcess: ChildProcessWithoutNullStreams;
let baseUrl: string;
let serverPort: number;

function testServerUrl(path: string): URL {
  const url = new URL(path, baseUrl);
  if (
    url.protocol !== 'http:' ||
    url.hostname !== '127.0.0.1' ||
    url.port !== String(serverPort) ||
    url.username !== '' ||
    url.password !== ''
  ) {
    throw new Error(`Refusing E2E request outside the local test server: ${url.origin}`);
  }
  return url;
}

async function findFreePort(): Promise<number> {
  const server = net.createServer();
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const address = server.address();
  server.close();
  await once(server, 'close');
  if (!address || typeof address === 'string') {
    throw new Error('Could not allocate a local port for E2E tests');
  }
  return address.port;
}

async function resetDatabase(): Promise<void> {
  const dbUrl = process.env.DATABASE_URL;
  if (!dbUrl || !dbUrl.toLowerCase().includes('test')) {
    throw new Error(`Refusing E2E reset against non-test database: ${dbUrl ?? '<unset>'}`);
  }

  await prisma.$executeRawUnsafe(
    'TRUNCATE "CaptureMarker", "Marker", "Feedback", "Artifact", "PracticeEntry", "Membership", "Course", "User", "RefreshToken" CASCADE;'
  );
}

async function seedCourse(): Promise<void> {
  await prisma.user.createMany({
    data: [
      { id: 'e2e-student', displayName: 'E2E Student', globalRole: 'student' },
      { id: 'e2e-teacher', displayName: 'E2E Teacher', globalRole: 'teacher' },
    ],
  });
  await prisma.course.create({
    data: { id: 'E2E_COURSE', title: 'E2E Practice Course' },
  });
  await prisma.membership.createMany({
    data: [
      { userId: 'e2e-student', courseId: 'E2E_COURSE', roleInCourse: 'student' },
      { userId: 'e2e-teacher', courseId: 'E2E_COURSE', roleInCourse: 'teacher' },
    ],
  });
}

async function waitForHealth(): Promise<void> {
  const deadline = Date.now() + 15_000;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`${baseUrl}/health`);
      if (response.ok) return;
    } catch {
      // Server is still starting. Keep polling the health endpoint until deadline.
    }
    await delay(100);
  }

  throw new Error(`E2E server did not become healthy:\n${serverLogs.join('')}`);
}

async function requestJson<T>(
  path: string,
  options: { method?: string; headers?: Record<string, string>; body?: string } = {}
): Promise<{ response: { status: number }; body: T }> {
  const headers = new Headers(options.headers);
  if (options.body !== undefined && !headers.has('content-type')) {
    headers.set('content-type', 'application/json');
  }

  const url = testServerUrl(path);
  const requestHeaders: Record<string, string> = {};
  headers.forEach((value, name) => {
    requestHeaders[name] = value;
  });
  const { status, text } = await new Promise<{ status: number; text: string }>(
    (resolve, reject) => {
      const request = httpRequest(
        {
          protocol: 'http:',
          hostname: '127.0.0.1',
          port: serverPort,
          method: options.method ?? 'GET',
          path: `${url.pathname}${url.search}`,
          headers: requestHeaders,
        },
        (response) => {
          response.setEncoding('utf8');
          let responseText = '';
          response.on('data', (chunk: string) => {
            responseText += chunk;
          });
          response.on('end', () => {
            resolve({ status: response.statusCode ?? 0, text: responseText });
          });
        }
      );
      request.on('error', reject);
      if (options.body !== undefined) request.write(options.body);
      request.end();
    }
  );
  const body = (text ? JSON.parse(text) : null) as T;
  return { response: { status }, body };
}

async function issueSession(userId: string): Promise<string> {
  const issue = await requestJson<{ code: string }>('/dev/issue', {
    method: 'POST',
    body: JSON.stringify({ userId }),
  });
  expect(issue.response.status).toBe(200);

  const session = await requestJson<{ accessToken: string }>('/auth/session', {
    method: 'POST',
    body: JSON.stringify({
      code: issue.body.code,
      redirectUri: 'resonance://auth-callback',
    }),
  });
  expect(session.response.status).toBe(201);
  return session.body.accessToken;
}

function authHeaders(accessToken: string): Record<string, string> {
  return { authorization: `Bearer ${accessToken}` };
}

beforeAll(async () => {
  await prisma.$connect();
  await resetDatabase();
  await seedCourse();

  serverPort = await findFreePort();
  baseUrl = `http://127.0.0.1:${serverPort}`;
  serverProcess = spawn('node', ['dist/index.js'], {
    cwd: process.cwd(),
    env: { ...process.env, PORT: String(serverPort) },
  });

  serverProcess.stdout.on('data', (chunk: Buffer) => serverLogs.push(chunk.toString()));
  serverProcess.stderr.on('data', (chunk: Buffer) => serverLogs.push(chunk.toString()));
  await waitForHealth();
});

afterAll(async () => {
  if (serverProcess && !serverProcess.killed) {
    serverProcess.kill('SIGTERM');
    await Promise.race([once(serverProcess, 'exit'), delay(5_000)]);
  }
  await prisma.$disconnect();
});

describe('process-level service E2E', () => {
  it('supports login, upload, submission, teacher review, and feedback retrieval', async () => {
    const login = await fetch(`${baseUrl}/auth/login`, { redirect: 'manual' });
    expect(login.status).toBe(302);
    expect(login.headers.get('location')).toBe('/dev/login');

    const studentToken = await issueSession('e2e-student');
    const teacherToken = await issueSession('e2e-teacher');

    const courses = await requestJson<Array<{ id: string; roleInCourse: string }>>('/courses', {
      headers: authHeaders(studentToken),
    });
    expect(courses.response.status).toBe(200);
    expect(courses.body).toContainEqual({
      id: 'E2E_COURSE',
      title: 'E2E Practice Course',
      roleInCourse: 'student',
    });

    const entry = await requestJson<{ id: string; status: string }>('/courses/E2E_COURSE/entries', {
      method: 'POST',
      headers: authHeaders(studentToken),
      body: JSON.stringify({
        id: 'e2e-entry-1',
        practiceDate: '2026-04-28T12:00:00.000Z',
        goalText: 'Stabilize the left-hand pattern',
        durationSeconds: 120,
        tags: ['scales', 'legato'],
        notes: 'Focus on even tempo.',
      }),
    });
    expect(entry.response.status).toBe(201);
    expect(entry.body.status).toBe('draft');

    const artifact = await requestJson<{ id: string; uploadState: string }>(
      '/entries/e2e-entry-1/artifacts',
      {
        method: 'POST',
        headers: authHeaders(studentToken),
        body: JSON.stringify({
          id: 'e2e-artifact-1',
          type: 'audio',
          durationSeconds: 120,
        }),
      }
    );
    expect(artifact.response.status).toBe(201);
    expect(artifact.body.uploadState).toBe('pending');

    const presign = await requestJson<{
      uploadUrl: string;
      storageKey: string;
      requiredHeaders: Record<string, string>;
    }>('/artifacts/e2e-artifact-1/presign', {
      method: 'POST',
      headers: authHeaders(studentToken),
    });
    expect(presign.response.status).toBe(200);
    expect(presign.body.storageKey).toBe('artifacts/e2e-entry-1/e2e-artifact-1');

    const upload = await fetch(presign.body.uploadUrl, {
      method: 'PUT',
      headers: presign.body.requiredHeaders,
      body: new Uint8Array([1, 2, 3, 4]),
    });
    expect(upload.ok).toBe(true);

    const confirmed = await requestJson<{ uploadState: string }>(
      '/artifacts/e2e-artifact-1/confirm',
      {
        method: 'POST',
        headers: authHeaders(studentToken),
      }
    );
    expect(confirmed.response.status).toBe(200);
    expect(confirmed.body.uploadState).toBe('uploaded');

    const submitted = await requestJson<{ status: string }>('/entries/e2e-entry-1/submit', {
      method: 'POST',
      headers: authHeaders(studentToken),
    });
    expect(submitted.response.status).toBe(200);
    expect(submitted.body.status).toBe('submitted');

    const queue = await requestJson<{ items: Array<{ id: string }>; nextCursor: string | null }>(
      '/courses/E2E_COURSE/review-queue?limit=5',
      { headers: authHeaders(teacherToken) }
    );
    expect(queue.response.status).toBe(200);
    expect(queue.body.items.map((item) => item.id)).toContain('e2e-entry-1');
    expect(queue.body.nextCursor).toBeNull();

    const feedback = await requestJson<{ id: string; teacherName: string }>('/feedback', {
      method: 'POST',
      headers: authHeaders(teacherToken),
      body: JSON.stringify({
        targetType: 'entry',
        targetId: 'e2e-entry-1',
        status: 'next_goal',
        commentsText: 'Keep the same tempo and increase phrase length next time.',
        markers: [{ timeSeconds: 12, text: 'Good release here.' }],
      }),
    });
    expect(feedback.response.status).toBe(201);
    expect(feedback.body.teacherName).toBe('E2E Teacher');

    const studentFeedback = await requestJson<
      Array<{ teacherName: string; commentsText: string; markers: Array<{ text: string }> }>
    >('/entries/e2e-entry-1/feedback', {
      headers: authHeaders(studentToken),
    });
    expect(studentFeedback.response.status).toBe(200);
    expect(studentFeedback.body).toHaveLength(1);
    expect(studentFeedback.body[0]).toMatchObject({
      teacherName: 'E2E Teacher',
      commentsText: 'Keep the same tempo and increase phrase length next time.',
    });
    expect(studentFeedback.body[0]?.markers[0]?.text).toBe('Good release here.');

    const lessonEntry = await requestJson<{ id: string; kind: string; captureProfile: string }>(
      '/courses/E2E_COURSE/entries',
      {
        method: 'POST',
        headers: authHeaders(studentToken),
        body: JSON.stringify({
          id: 'e2e-teaching-1',
          kind: 'teaching_lesson',
          practiceDate: '2026-04-29T10:00:00.000Z',
          goalText: 'Reflect on rhythm-teaching sequence',
          tags: ['lehramt', 'rhythmus'],
          notes: 'Focus on modelling, transitions, and participation.',
          consentConfirmed: true,
          consentScope: 'private_course_review',
          captureProfile: 'teacher_learner',
        }),
      }
    );
    expect(lessonEntry.response.status).toBe(201);
    expect(lessonEntry.body.kind).toBe('teaching_lesson');
    expect(lessonEntry.body.captureProfile).toBe('teacher_learner');

    const lessonArtifact = await requestJson<{ id: string; uploadState: string }>(
      '/entries/e2e-teaching-1/artifacts',
      {
        method: 'POST',
        headers: authHeaders(studentToken),
        body: JSON.stringify({
          id: 'e2e-video-1',
          type: 'video',
          durationSeconds: 90,
        }),
      }
    );
    expect(lessonArtifact.response.status).toBe(201);
    expect(lessonArtifact.body.uploadState).toBe('pending');

    const lessonPresign = await requestJson<{
      uploadUrl: string;
      storageKey: string;
      requiredHeaders: Record<string, string>;
    }>('/artifacts/e2e-video-1/presign', {
      method: 'POST',
      headers: authHeaders(studentToken),
    });
    expect(lessonPresign.response.status).toBe(200);
    expect(lessonPresign.body.storageKey).toBe('artifacts/e2e-teaching-1/e2e-video-1');

    const lessonUpload = await fetch(lessonPresign.body.uploadUrl, {
      method: 'PUT',
      headers: lessonPresign.body.requiredHeaders,
      body: new Uint8Array([5, 6, 7, 8]),
    });
    expect(lessonUpload.ok).toBe(true);

    const lessonConfirmed = await requestJson<{ uploadState: string }>(
      '/artifacts/e2e-video-1/confirm',
      {
        method: 'POST',
        headers: authHeaders(studentToken),
      }
    );
    expect(lessonConfirmed.response.status).toBe(200);
    expect(lessonConfirmed.body.uploadState).toBe('uploaded');

    const lessonMarkers = await requestJson<Array<{ id: string; kind: string }>>(
      '/entries/e2e-teaching-1/capture-markers',
      {
        method: 'PUT',
        headers: authHeaders(studentToken),
        body: JSON.stringify({
          markers: [
            {
              id: 'e2e-capture-marker-1',
              artifactId: 'e2e-video-1',
              timeSeconds: 18,
              kind: 'phase_modeling',
              note: 'Teacher models the rhythm before student response.',
            },
          ],
        }),
      }
    );
    expect(lessonMarkers.response.status).toBe(200);
    expect(lessonMarkers.body[0]).toMatchObject({
      id: 'e2e-capture-marker-1',
      kind: 'phase_modeling',
    });

    const lessonSubmitted = await requestJson<{ status: string }>(
      '/entries/e2e-teaching-1/submit',
      {
        method: 'POST',
        headers: authHeaders(studentToken),
      }
    );
    expect(lessonSubmitted.response.status).toBe(200);
    expect(lessonSubmitted.body.status).toBe('submitted');

    const lessonQueue = await requestJson<{
      items: Array<{ id: string; captureProfile: string; captureMarkerCount: number }>;
    }>('/courses/E2E_COURSE/review-queue?limit=5', {
      headers: authHeaders(teacherToken),
    });
    expect(lessonQueue.response.status).toBe(200);
    expect(lessonQueue.body.items).toContainEqual(
      expect.objectContaining({
        id: 'e2e-teaching-1',
        captureProfile: 'teacher_learner',
        captureMarkerCount: 1,
      })
    );

    const lessonDetail = await requestJson<{
      captureMarkers: Array<{ id: string; kind: string; timeSeconds: number }>;
    }>('/entries/e2e-teaching-1', {
      headers: authHeaders(teacherToken),
    });
    expect(lessonDetail.response.status).toBe(200);
    expect(lessonDetail.body.captureMarkers).toContainEqual(
      expect.objectContaining({
        id: 'e2e-capture-marker-1',
        kind: 'phase_modeling',
        timeSeconds: 18,
      })
    );
  });
});
