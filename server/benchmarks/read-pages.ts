/** Synthetic read workload, scoped to the guarded test database and rolled back on completion. */
import { randomUUID } from 'node:crypto';
import { performance } from 'node:perf_hooks';
import { PrismaClient, Prisma } from '@prisma/client';
import { assertTestDatabaseUrl } from '../../scripts/assert-database-target.mjs';

assertTestDatabaseUrl(process.env.DATABASE_URL);

const prisma = new PrismaClient();
const rowCount = 10_000;
const repetitions = 20;
const warmups = 3;
const runId = `benchmark-${randomUUID()}`;
const createdAt = new Date('2026-09-08T00:00:00Z');
const rollback = new Error('Rollback synthetic benchmark fixture');
type Reader = Prisma.TransactionClient;

async function seed(tx: Reader) {
  await tx.user.create({
    data: { id: runId, displayName: 'Synthetic benchmark student', globalRole: 'student' },
  });
  await tx.course.create({ data: { id: runId, title: 'Synthetic read benchmark' } });
  for (let offset = 0; offset < rowCount; offset += 500) {
    await tx.practiceEntry.createMany({
      data: Array.from({ length: 500 }, (_, index) => ({
        id: `${runId}-${String(offset + index).padStart(5, '0')}`,
        courseId: runId,
        studentId: runId,
        goalText: 'Synthetic practice goal',
        practiceDate: new Date(createdAt.getTime() - (offset + index) * 60_000),
        createdAt,
        status: 'submitted' as const,
        tags: [],
      })),
    });
  }
  // Attach the maximum supported capture-marker count to the first page.
  for (let index = 0; index < 50; index += 1) {
    const entryId = `${runId}-${String(index).padStart(5, '0')}`;
    const artifactId = `${entryId}-audio`;
    await tx.artifact.create({
      data: { id: artifactId, entryId, type: 'audio', durationSeconds: 60 },
    });
    await tx.captureMarker.createMany({
      data: Array.from({ length: 50 }, (_, marker) => ({
        id: `${artifactId}-${marker}`,
        entryId,
        artifactId,
        studentId: runId,
        timeSeconds: marker,
        kind: 'privacy_note' as const,
        note: 'Synthetic marker',
      })),
    });
  }
}

function distribution(samples: number[]) {
  const sorted = [...samples].sort((left, right) => left - right);
  return {
    minMs: sorted[0],
    medianMs: sorted[Math.floor(sorted.length / 2)],
    p95Ms: sorted[Math.ceil(sorted.length * 0.95) - 1],
    maxMs: sorted.at(-1),
  };
}

async function measure(tx: Reader) {
  // Delay app imports until after the target guard. No .env file may choose this database.
  const { readEntryPage, readReviewQueuePage } =
    await import('../src/modules/entries/application/queries.js');
  const { toEntryResponseDto, toEntrySummaryDto } =
    await import('../src/modules/entries/application/dto.js');
  // These helpers only use model delegates present on the transaction client.
  const reader = tx as unknown as PrismaClient;
  const fullSamples: number[] = [];
  const summarySamples: number[] = [];
  const studentSamples: number[] = [];
  let fullBytes = 0;
  let summaryBytes = 0;
  for (let iteration = -warmups; iteration < repetitions; iteration += 1) {
    const full = async () => {
      const start = performance.now();
      const page = await readEntryPage(
        reader,
        { courseId: runId, status: 'submitted', deletedAt: null },
        undefined,
        50
      );
      fullBytes = Buffer.byteLength(JSON.stringify(page.items.map(toEntryResponseDto)));
      if (iteration >= 0) fullSamples.push(performance.now() - start);
    };
    const summary = async () => {
      const start = performance.now();
      const page = await readReviewQueuePage(reader, runId, undefined, 50);
      summaryBytes = Buffer.byteLength(
        JSON.stringify(
          page.items.map((entry) => ({
            ...toEntrySummaryDto(entry),
            captureMarkerCount: entry._count.captureMarkers,
          }))
        )
      );
      if (iteration >= 0) summarySamples.push(performance.now() - start);
    };
    // Alternate order to reduce cache/order bias in the paired comparison.
    for (const operation of iteration % 2 === 0 ? [full, summary] : [summary, full])
      await operation();
    const studentStart = performance.now();
    await readEntryPage(
      reader,
      { courseId: runId, studentId: runId, deletedAt: null },
      undefined,
      50
    );
    if (iteration >= 0) studentSamples.push(performance.now() - studentStart);
  }
  const studentPlan = await tx.$queryRaw`
    EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT * FROM "PracticeEntry"
    WHERE "courseId" = ${runId} AND "studentId" = ${runId} AND "deletedAt" IS NULL
    ORDER BY "practiceDate" DESC, "createdAt" DESC, "id" DESC LIMIT 51`;
  const reviewPlan = await tx.$queryRaw`
    EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT * FROM "PracticeEntry"
    WHERE "courseId" = ${runId} AND "status" = 'submitted' AND "deletedAt" IS NULL
    ORDER BY "practiceDate" DESC, "createdAt" DESC, "id" DESC LIMIT 51`;
  const postgresVersion = await tx.$queryRaw<Array<{ version: string }>>`SELECT version()`;
  return {
    node: process.version,
    prisma: Prisma.prismaVersion.client,
    postgres: postgresVersion[0]?.version,
    statistics: 'Existing table statistics; uncommitted synthetic rows are not analyzed',
    rowCount,
    markersPerVisibleEntry: 50,
    warmups,
    repetitions,
    pageSize: 50,
    fixtureEpoch: createdAt.toISOString(),
    fullProjection: { ...distribution(fullSamples), bytes: fullBytes },
    reviewSummary: { ...distribution(summarySamples), bytes: summaryBytes },
    studentPage: distribution(studentSamples),
    studentPlan,
    reviewPlan,
  };
}

let report: Awaited<ReturnType<typeof measure>> | undefined;
try {
  await prisma.$transaction(
    async (tx) => {
      await seed(tx);
      report = await measure(tx);
      throw rollback;
    },
    { timeout: 180_000 }
  );
} catch (error) {
  if (error !== rollback) throw error;
} finally {
  await prisma.$disconnect();
}
console.log(JSON.stringify(report, null, 2));
