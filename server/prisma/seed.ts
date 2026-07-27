/** Minimal development seed for the baseline application identities. */
import { PrismaClient } from '@prisma/client';

const prisma = new PrismaClient();

async function main() {
  const studentId = 'user-student-1';
  const teacherId = 'user-teacher-1';

  await prisma.user.upsert({
    where: { id: studentId },
    update: {},
    create: {
      id: studentId,
      displayName: 'Student One',
      globalRole: 'student',
    },
  });

  await prisma.user.upsert({
    where: { id: teacherId },
    update: {},
    create: {
      id: teacherId,
      displayName: 'Teacher One',
      globalRole: 'teacher',
    },
  });

  const courseId = 'COURSE_101';

  await prisma.course.upsert({
    where: { id: courseId },
    update: {},
    create: {
      id: courseId,
      title: 'Piano Technique 101',
    },
  });

  await prisma.membership.upsert({
    where: { userId_courseId: { userId: studentId, courseId } },
    update: { roleInCourse: 'student' },
    create: { userId: studentId, courseId, roleInCourse: 'student' },
  });

  await prisma.membership.upsert({
    where: { userId_courseId: { userId: teacherId, courseId } },
    update: { roleInCourse: 'teacher' },
    create: { userId: teacherId, courseId, roleInCourse: 'teacher' },
  });

  const entryId = 'entry-seed-001';
  await prisma.practiceEntry.upsert({
    where: { id: entryId },
    update: {},
    create: {
      id: entryId,
      courseId,
      studentId,
      practiceDate: new Date(),
      goalText: 'Improve legato in Chopin Nocturne',
      durationSeconds: 90,
      tags: ['Chopin', 'legato'],
      notes: 'Focus on left-hand balance',
      status: 'submitted',
    },
  });
}

main()
  .catch((err) => {
    console.error(err);
    process.exit(1);
  })
  .finally(async () => {
    await prisma.$disconnect();
  });
