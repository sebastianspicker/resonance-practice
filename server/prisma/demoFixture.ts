import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import type { PrismaClient } from '@prisma/client';

const DEMO_ID_PREFIX = 'demo_';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const fixturePath = path.resolve(__dirname, '../../demo/fixtures/mock-university.json');

export interface DemoFixture {
  meta: {
    version: string;
    generatedFor: string;
    universityName: string;
  };
  users: Array<{ id: string; displayName: string; globalRole: 'student' | 'teacher' }>;
  courses: Array<{ id: string; title: string }>;
  memberships: Array<{
    userId: string;
    courseId: string;
    roleInCourse: 'student' | 'teacher';
  }>;
  entries: Array<{
    id: string;
    courseId: string;
    studentId: string;
    createdAt: string;
    practiceDate: string;
    goalText: string;
    durationSeconds: number | null;
    tags: string[];
    notes: string | null;
    status: 'draft' | 'submitted' | 'reviewed';
  }>;
  artifacts: Array<{
    id: string;
    entryId: string;
    type: 'audio' | 'video';
    durationSeconds: number;
    createdAt: string;
    uploadState: 'pending' | 'uploading' | 'uploaded' | 'failed';
    syncPhase?: 'queued' | 'uploading' | 'confirming' | 'uploaded' | 'failed';
    storageKey: string | null;
    remoteUrl: string | null;
    localPath?: string;
  }>;
  feedback: Array<{
    id: string;
    targetType: 'entry' | 'artifact';
    targetId: string;
    teacherId: string;
    createdAt: string;
    status: 'ok' | 'needs_revision' | 'next_goal';
    commentsText: string;
    markers: Array<{
      id: string;
      timeSeconds: number;
      text: string;
    }>;
  }>;
  syncQueue?: Array<{
    id: string;
    type: string;
    status: string;
    retryCount: number;
    lastError: string | null;
    createdAt: string;
    nextAttemptAt: string | null;
    payload: Record<string, unknown>;
  }>;
}

function assertArray(value: unknown, name: string): asserts value is unknown[] {
  if (!Array.isArray(value)) {
    throw new Error(`Invalid demo fixture: expected array at "${name}"`);
  }
}

function ensureDemoId(id: string, fieldName: string) {
  if (!id.startsWith(DEMO_ID_PREFIX)) {
    throw new Error(
      `Invalid demo fixture: ${fieldName} must start with "${DEMO_ID_PREFIX}" (got "${id}")`
    );
  }
}

export async function loadDemoFixture(): Promise<DemoFixture> {
  const raw = await readFile(fixturePath, 'utf8');
  const parsed = JSON.parse(raw) as DemoFixture;

  if (!parsed.meta?.universityName) {
    throw new Error('Invalid demo fixture: missing meta.universityName');
  }

  assertArray(parsed.users, 'users');
  assertArray(parsed.courses, 'courses');
  assertArray(parsed.memberships, 'memberships');
  assertArray(parsed.entries, 'entries');
  assertArray(parsed.artifacts, 'artifacts');
  assertArray(parsed.feedback, 'feedback');

  for (const user of parsed.users) {
    ensureDemoId(user.id, 'users[].id');
  }
  for (const course of parsed.courses) {
    ensureDemoId(course.id, 'courses[].id');
  }
  for (const entry of parsed.entries) {
    ensureDemoId(entry.id, 'entries[].id');
  }
  for (const artifact of parsed.artifacts) {
    ensureDemoId(artifact.id, 'artifacts[].id');
  }
  for (const item of parsed.feedback) {
    ensureDemoId(item.id, 'feedback[].id');
    for (const marker of item.markers) {
      ensureDemoId(marker.id, 'feedback[].markers[].id');
    }
  }

  return parsed;
}

export async function resetDemoData(prisma: PrismaClient): Promise<void> {
  await prisma.$transaction(async (tx) => {
    await tx.marker.deleteMany({
      where: {
        OR: [
          { id: { startsWith: DEMO_ID_PREFIX } },
          { feedbackId: { startsWith: DEMO_ID_PREFIX } },
        ],
      },
    });

    await tx.feedback.deleteMany({
      where: {
        OR: [
          { id: { startsWith: DEMO_ID_PREFIX } },
          { targetId: { startsWith: DEMO_ID_PREFIX } },
          { teacherId: { startsWith: DEMO_ID_PREFIX } },
        ],
      },
    });

    await tx.artifact.deleteMany({
      where: {
        OR: [{ id: { startsWith: DEMO_ID_PREFIX } }, { entryId: { startsWith: DEMO_ID_PREFIX } }],
      },
    });

    await tx.practiceEntry.deleteMany({
      where: {
        OR: [
          { id: { startsWith: DEMO_ID_PREFIX } },
          { courseId: { startsWith: DEMO_ID_PREFIX } },
          { studentId: { startsWith: DEMO_ID_PREFIX } },
        ],
      },
    });

    await tx.membership.deleteMany({
      where: {
        OR: [
          { userId: { startsWith: DEMO_ID_PREFIX } },
          { courseId: { startsWith: DEMO_ID_PREFIX } },
        ],
      },
    });

    await tx.refreshToken.deleteMany({ where: { userId: { startsWith: DEMO_ID_PREFIX } } });
    await tx.course.deleteMany({ where: { id: { startsWith: DEMO_ID_PREFIX } } });
    await tx.user.deleteMany({ where: { id: { startsWith: DEMO_ID_PREFIX } } });
  });
}
