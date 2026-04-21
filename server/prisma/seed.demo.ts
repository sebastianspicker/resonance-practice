import { PrismaClient } from '@prisma/client';
import { loadDemoFixture, resetDemoData } from './demoFixture.js';

const prisma = new PrismaClient();

async function main() {
  const fixture = await loadDemoFixture();

  await resetDemoData(prisma);

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

  for (const entry of fixture.entries) {
    await prisma.practiceEntry.upsert({
      where: { id: entry.id },
      update: {
        courseId: entry.courseId,
        studentId: entry.studentId,
        practiceDate: new Date(entry.practiceDate),
        goalText: entry.goalText,
        durationSeconds: entry.durationSeconds,
        tags: entry.tags,
        notes: entry.notes,
        status: entry.status,
        deletedAt: null,
      },
      create: {
        id: entry.id,
        courseId: entry.courseId,
        studentId: entry.studentId,
        createdAt: new Date(entry.createdAt),
        practiceDate: new Date(entry.practiceDate),
        goalText: entry.goalText,
        durationSeconds: entry.durationSeconds,
        tags: entry.tags,
        notes: entry.notes,
        status: entry.status,
        deletedAt: null,
      },
    });
  }

  for (const artifact of fixture.artifacts) {
    await prisma.artifact.upsert({
      where: { id: artifact.id },
      update: {
        entryId: artifact.entryId,
        type: artifact.type,
        durationSeconds: artifact.durationSeconds,
        uploadState: artifact.uploadState,
        storageKey: artifact.storageKey,
        remoteUrl: artifact.remoteUrl,
      },
      create: {
        id: artifact.id,
        entryId: artifact.entryId,
        type: artifact.type,
        durationSeconds: artifact.durationSeconds,
        createdAt: new Date(artifact.createdAt),
        uploadState: artifact.uploadState,
        storageKey: artifact.storageKey,
        remoteUrl: artifact.remoteUrl,
      },
    });
  }

  for (const item of fixture.feedback) {
    await prisma.feedback.upsert({
      where: { id: item.id },
      update: {
        targetType: item.targetType,
        targetId: item.targetId,
        teacherId: item.teacherId,
        status: item.status,
        commentsText: item.commentsText,
        createdAt: new Date(item.createdAt),
      },
      create: {
        id: item.id,
        targetType: item.targetType,
        targetId: item.targetId,
        teacherId: item.teacherId,
        createdAt: new Date(item.createdAt),
        status: item.status,
        commentsText: item.commentsText,
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

  const summary = {
    universityName: fixture.meta.universityName,
    users: fixture.users.length,
    courses: fixture.courses.length,
    memberships: fixture.memberships.length,
    entries: fixture.entries.length,
    artifacts: fixture.artifacts.length,
    feedback: fixture.feedback.length,
  };

  console.log('Seeded demo fixture successfully:', summary);
}

main()
  .catch((err) => {
    console.error('Failed to seed demo fixture:', err);
    process.exit(1);
  })
  .finally(async () => {
    await prisma.$disconnect();
  });
