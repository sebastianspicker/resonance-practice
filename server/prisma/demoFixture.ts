/** Deterministic demo-fixture loading, seeding, and safe reset helpers. */
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import type { PrismaClient } from '@prisma/client';
export { assertDemoDatabaseUrl } from '../../scripts/assert-demo-database-url.mjs';

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
    kind?: 'practice' | 'teaching_lesson';
    consentConfirmedAt?: string | null;
    consentScope?: 'private_course_review' | null;
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
    expectedSizeBytes: number | null;
    uploadExpiresAt: string | null;
    confirmationToken: string | null;
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

  validateDemoFixture(parsed);
  return parsed;
}

const validateFixtureStructure = (fixture: DemoFixture): void => {
  if (!fixture.meta?.universityName) {
    throw new Error('Invalid demo fixture: missing meta.universityName');
  }

  assertArray(fixture.users, 'users');
  assertArray(fixture.courses, 'courses');
  assertArray(fixture.memberships, 'memberships');
  assertArray(fixture.entries, 'entries');
  assertArray(fixture.artifacts, 'artifacts');
  assertArray(fixture.feedback, 'feedback');
};

const validateFixtureIds = (fixture: DemoFixture): void => {
  for (const user of fixture.users) {
    ensureDemoId(user.id, 'users[].id');
  }
  for (const course of fixture.courses) {
    ensureDemoId(course.id, 'courses[].id');
  }
  for (const entry of fixture.entries) {
    ensureDemoId(entry.id, 'entries[].id');
  }
};

const validateFixtureArtifacts = (fixture: DemoFixture): void => {
  for (const artifact of fixture.artifacts) {
    ensureDemoId(artifact.id, 'artifacts[].id');
    if (!fixture.entries.some((entry) => entry.id === artifact.entryId)) {
      throw new Error(`Invalid demo fixture: artifact parent entry not found: ${artifact.entryId}`);
    }
    if (!Number.isInteger(artifact.expectedSizeBytes) || artifact.expectedSizeBytes <= 0) {
      throw new Error(
        `Invalid demo fixture: artifact expectedSizeBytes must be positive: ${artifact.id}`
      );
    }
    validateArtifactStorageState(artifact);
  }
};

const validateArtifactStorageState = (artifact: DemoFixture['artifacts'][number]): void => {
  if (artifact.uploadState === 'uploaded') {
    if (!artifact.storageKey || !artifact.remoteUrl) {
      throw new Error(
        `Invalid demo fixture: uploaded artifact requires storage metadata: ${artifact.id}`
      );
    }
    if (artifact.uploadExpiresAt !== null || artifact.confirmationToken !== null) {
      throw new Error(
        `Invalid demo fixture: uploaded artifact has an active upload slot: ${artifact.id}`
      );
    }
    return;
  }

  if (artifact.uploadState === 'uploading') {
    if (!artifact.storageKey || !artifact.uploadExpiresAt) {
      throw new Error(
        `Invalid demo fixture: uploading artifact requires an upload slot: ${artifact.id}`
      );
    }
    return;
  }

  if (hasInactiveUploadMetadata(artifact)) {
    throw new Error(
      `Invalid demo fixture: inactive artifact has active upload metadata: ${artifact.id}`
    );
  }
};

const hasInactiveUploadMetadata = (artifact: DemoFixture['artifacts'][number]): boolean =>
  artifact.storageKey !== null ||
  artifact.remoteUrl !== null ||
  artifact.uploadExpiresAt !== null ||
  artifact.confirmationToken !== null;

const validateSubmittedEntries = (entries: DemoFixture['entries']): void => {
  if (entries.filter((entry) => entry.status === 'submitted').length < 2) {
    throw new Error('Invalid demo fixture: expected at least two submitted entries.');
  }
};

const validateFixtureFeedback = (fixture: DemoFixture): void => {
  for (const item of fixture.feedback) {
    ensureDemoId(item.id, 'feedback[].id');
    for (const marker of item.markers) {
      ensureDemoId(marker.id, 'feedback[].markers[].id');
    }
    const entryId = resolveDemoFeedbackEntryId(fixture, item);
    const parentEntry = fixture.entries.find((entry) => entry.id === entryId);
    if (parentEntry?.status !== 'reviewed') {
      throw new Error(`Invalid demo fixture: feedback parent entry must be reviewed: ${entryId}`);
    }
  }
};

function validateDemoFixture(fixture: DemoFixture): void {
  validateFixtureStructure(fixture);
  validateFixtureIds(fixture);
  validateFixtureArtifacts(fixture);
  validateSubmittedEntries(fixture.entries);
  validateFixtureFeedback(fixture);
}

export function resolveDemoFeedbackEntryId(
  fixture: DemoFixture,
  feedback: DemoFixture['feedback'][number]
): string {
  if (feedback.targetType === 'entry') {
    if (!fixture.entries.some((entry) => entry.id === feedback.targetId)) {
      throw new Error(
        `Invalid demo fixture: feedback target entry not found: ${feedback.targetId}`
      );
    }
    return feedback.targetId;
  }

  const artifact = fixture.artifacts.find((candidate) => candidate.id === feedback.targetId);
  if (!artifact) {
    throw new Error(
      `Invalid demo fixture: feedback target artifact not found: ${feedback.targetId}`
    );
  }
  return artifact.entryId;
}

export async function resetDemoData(prisma: PrismaClient): Promise<void> {
  await prisma.$transaction(async (tx) => {
    // A previous demo-entry deletion may have queued one of the fixture's
    // static storage keys. Remove that stale job before reseeding; otherwise
    // the periodic cleanup worker could delete media referenced by fresh rows.
    await tx.storageDeletionJob.deleteMany({
      where: { entryId: { startsWith: DEMO_ID_PREFIX } },
    });
    await tx.deletedEntryTombstone.deleteMany({
      where: { id: { startsWith: DEMO_ID_PREFIX } },
    });

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
          { entryId: { startsWith: DEMO_ID_PREFIX } },
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
