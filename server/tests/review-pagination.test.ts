import request from 'supertest';
import { describe, expect, it } from 'vitest';
import { app, prisma } from './support/testUtils.js';
import { installV1SyncSuite } from './v1-sync/support.js';

describe('bounded review reads', () => {
  const suite = installV1SyncSuite();
  const createdAt = new Date('2026-09-08T12:00:00Z');

  async function seedEntry(id: string, status: 'draft' | 'submitted' = 'submitted') {
    return prisma.practiceEntry.create({
      data: {
        id,
        courseId: 'COURSE_TEST',
        studentId: 'student-1',
        status,
        practiceDate: createdAt,
        goalText: 'Synthetic pagination fixture',
        tags: [],
      },
    });
  }

  function feedbackRequest(
    entryId: string,
    query: Record<string, string | number> = {},
    teacher = false
  ) {
    return request(app.server)
      .get(`/api/v1/entries/${entryId}/feedback`)
      .set('authorization', `Bearer ${teacher ? suite.teacherToken : suite.studentToken}`)
      .query(query);
  }

  it('pages tied timestamps without gaps and rejects cursors belonging to another entry', async () => {
    await seedEntry('paged-entry');
    await seedEntry('other-entry');
    await prisma.feedback.createMany({
      data: Array.from({ length: 53 }, (_, index) => ({
        id: `feedback-${String(index).padStart(3, '0')}`,
        entryId: index === 52 ? 'other-entry' : 'paged-entry',
        targetType: 'entry' as const,
        targetId: 'paged-entry',
        teacherId: 'teacher-1',
        createdAt,
        status: 'next_goal' as const,
        commentsText: 'Synthetic feedback',
      })),
    });

    const first = await feedbackRequest('paged-entry');
    expect(first.status).toBe(200);
    expect(first.body.items).toHaveLength(50);
    expect(first.body.nextCursor).toBe('feedback-049');
    const second = await feedbackRequest('paged-entry', { cursor: first.body.nextCursor });
    expect(second.status).toBe(200);
    expect(second.body.items.map((item: { id: string }) => item.id)).toEqual([
      'feedback-050',
      'feedback-051',
    ]);
    expect(second.body.nextCursor).toBeNull();
    expect((await feedbackRequest('paged-entry', { cursor: 'feedback-052' })).status).toBe(400);
    expect((await feedbackRequest('paged-entry', { limit: 0 })).status).toBe(400);
  });

  it('retains visibility checks on every feedback page and returns an empty envelope', async () => {
    await seedEntry('private-entry', 'draft');
    expect((await feedbackRequest('private-entry', {}, true)).status).toBe(403);
    const empty = await feedbackRequest('private-entry');
    expect(empty.body).toEqual({ items: [], nextCursor: null });
    await prisma.membership.delete({
      where: { userId_courseId: { userId: 'student-1', courseId: 'COURSE_TEST' } },
    });
    expect((await feedbackRequest('private-entry')).status).toBe(403);
  });

  it('projects marker counts in the queue while preserving markers on detail reads', async () => {
    await seedEntry('marker-entry');
    await prisma.artifact.create({
      data: { id: 'marker-artifact', entryId: 'marker-entry', type: 'audio', durationSeconds: 60 },
    });
    await prisma.captureMarker.createMany({
      data: Array.from({ length: 50 }, (_, index) => ({
        id: `marker-${index}`,
        entryId: 'marker-entry',
        artifactId: 'marker-artifact',
        studentId: 'student-1',
        timeSeconds: index,
        kind: 'privacy_note' as const,
        note: 'Synthetic capture marker',
      })),
    });
    const queue = await request(app.server)
      .get('/api/v1/courses/COURSE_TEST/review-queue')
      .set('authorization', `Bearer ${suite.teacherToken}`);
    expect(queue.status).toBe(200);
    expect(queue.body.items[0].captureMarkerCount).toBe(50);
    expect(queue.body.items[0]).not.toHaveProperty('captureMarkers');
    expect(queue.body.items[0].artifacts[0]).not.toHaveProperty('storageKey');
    const detail = await request(app.server)
      .get('/api/v1/entries/marker-entry')
      .set('authorization', `Bearer ${suite.teacherToken}`);
    expect(detail.body.captureMarkers).toHaveLength(50);
    expect(Buffer.byteLength(JSON.stringify(queue.body.items[0]))).toBeLessThan(
      Buffer.byteLength(JSON.stringify(detail.body))
    );
  });
});
