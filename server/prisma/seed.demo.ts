import { PrismaClient } from '@prisma/client';
import type { DemoFixture } from './demoFixture.js';
import { loadDemoFixture, resetDemoData } from './demoFixture.js';

const prisma = new PrismaClient();

async function seedUsers(fixture: DemoFixture) {
  for (const user of fixture.users) {
    await prisma.user.upsert({
      where: { id: user.id },
      update: {
        displayName: user.displayName,
        globalRole: user.globalRole,
      },
      create: {
        id: user.id,
        displayName: user.displayName,
        globalRole: user.globalRole,
      },
    });
  }
}

async function seedCourses(fixture: DemoFixture) {
  for (const course of fixture.courses) {
    await prisma.course.upsert({
      where: { id: course.id },
      update: {
        title: course.title,
      },
      create: {
        id: course.id,
        title: course.title,
      },
    });
  }
}

async function seedMemberships(fixture: DemoFixture) {
  for (const membership of fixture.memberships) {
    await prisma.membership.upsert({
      where: {
        userId_courseId: {
          userId: membership.userId,
          courseId: membership.courseId,
        },
      },
      update: {
        roleInCourse: membership.roleInCourse,
      },
      create: {
        userId: membership.userId,
        courseId: membership.courseId,
        roleInCourse: membership.roleInCourse,
      },
    });
  }
}

function entryWriteData(entry: DemoFixture['entries'][number]) {
  return {
    courseId: entry.courseId,
    studentId: entry.studentId,
    kind: entry.kind ?? 'practice',
    practiceDate: new Date(entry.practiceDate),
    goalText: entry.goalText,
    durationSeconds: entry.durationSeconds,
    tags: entry.tags,
    notes: entry.notes,
    status: entry.status,
    consentConfirmedAt: entry.consentConfirmedAt ? new Date(entry.consentConfirmedAt) : null,
    consentScope: entry.consentScope ?? null,
    deletedAt: null,
  };
}

async function seedEntries(fixture: DemoFixture) {
  for (const entry of fixture.entries) {
    const writeData = entryWriteData(entry);
    await prisma.practiceEntry.upsert({
      where: { id: entry.id },
      update: writeData,
      create: {
        id: entry.id,
        createdAt: new Date(entry.createdAt),
        ...writeData,
      },
    });
  }
}

function artifactWriteData(artifact: DemoFixture['artifacts'][number]) {
  return {
    entryId: artifact.entryId,
    type: artifact.type,
    durationSeconds: artifact.durationSeconds,
    uploadState: artifact.uploadState,
    storageKey: artifact.storageKey,
    remoteUrl: artifact.remoteUrl,
  };
}

async function seedArtifacts(fixture: DemoFixture) {
  for (const artifact of fixture.artifacts) {
    const writeData = artifactWriteData(artifact);
    await prisma.artifact.upsert({
      where: { id: artifact.id },
      update: writeData,
      create: {
        id: artifact.id,
        createdAt: new Date(artifact.createdAt),
        ...writeData,
      },
    });
  }
}

function feedbackWriteData(item: DemoFixture['feedback'][number]) {
  return {
    targetType: item.targetType,
    targetId: item.targetId,
    teacherId: item.teacherId,
    status: item.status,
    commentsText: item.commentsText,
    createdAt: new Date(item.createdAt),
  };
}

async function seedFeedback(fixture: DemoFixture) {
  for (const item of fixture.feedback) {
    const writeData = feedbackWriteData(item);
    await prisma.feedback.upsert({
      where: { id: item.id },
      update: writeData,
      create: {
        id: item.id,
        ...writeData,
      },
    });

    await prisma.marker.deleteMany({ where: { feedbackId: item.id } });

    if (item.markers.length > 0) {
      await prisma.marker.createMany({
        data: item.markers.map((marker) => ({
          id: marker.id,
          feedbackId: item.id,
          timeSeconds: marker.timeSeconds,
          text: marker.text,
        })),
      });
    }
  }
}

function demoSummary(fixture: DemoFixture) {
  return {
    universityName: fixture.meta.universityName,
    users: fixture.users.length,
    courses: fixture.courses.length,
    memberships: fixture.memberships.length,
    entries: fixture.entries.length,
    artifacts: fixture.artifacts.length,
    feedback: fixture.feedback.length,
  };
}

async function main() {
  const fixture = await loadDemoFixture();

  await resetDemoData(prisma);
  await seedUsers(fixture);
  await seedCourses(fixture);
  await seedMemberships(fixture);
  await seedEntries(fixture);
  await seedArtifacts(fixture);
  await seedFeedback(fixture);

  console.log('Seeded demo fixture successfully:', demoSummary(fixture));
}

main()
  .catch((err) => {
    console.error('Failed to seed demo fixture:', err);
    process.exit(1);
  })
  .finally(async () => {
    await prisma.$disconnect();
  });
