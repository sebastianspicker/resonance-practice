import request from 'supertest';
import { beforeAll, afterAll, beforeEach, describe, expect, it } from 'vitest';
import {
  app,
  setupApp,
  teardownApp,
  resetDb,
  seedBasic,
  getAccessToken,
  prisma,
  s3Mock,
} from './testUtils.js';

function login(role: 'student' | 'teacher') {
  const userId = role === 'student' ? 'student-1' : 'teacher-1';
  return getAccessToken(role, { userId });
}

describe('edge cases', () => {
  beforeAll(async () => {
    await setupApp();
  });

  afterAll(async () => {
    await teardownApp();
  });

  beforeEach(async () => {
    s3Mock.reset();
    await resetDb();
    await seedBasic();
  });

  // ═══════════════════════════════════════════════════════════════════
  // Category 1: Empty / Minimal Inputs
  // ═══════════════════════════════════════════════════════════════════

  describe('Category 1: Empty/minimal inputs', () => {
    describe('POST /courses/:courseId/entries', () => {
      it('should reject empty string goalText (minLength: 1)', async () => {
        const token = await login('student');
        const res = await request(app.server)
          .post('/courses/COURSE_TEST/entries')
          .set('Authorization', `Bearer ${token}`)
          .send({
            id: 'entry-empty-goal',
            practiceDate: new Date().toISOString(),
            goalText: '',
            tags: [],
          });
        // goalText now requires minLength: 1
        expect(res.status).toBe(400);
        expect(res.body.error.code).toBe('VALIDATION_ERROR');
      });

      it('should accept empty tags array', async () => {
        const token = await login('student');
        const res = await request(app.server)
          .post('/courses/COURSE_TEST/entries')
          .set('Authorization', `Bearer ${token}`)
          .send({
            id: 'entry-empty-tags',
            practiceDate: new Date().toISOString(),
            goalText: 'Some goal',
            tags: [],
          });
        expect(res.status).toBe(201);
        expect(res.body.tags).toEqual([]);
      });

      it('should accept zero durationSeconds', async () => {
        const token = await login('student');
        const res = await request(app.server)
          .post('/courses/COURSE_TEST/entries')
          .set('Authorization', `Bearer ${token}`)
          .send({
            id: 'entry-zero-dur',
            practiceDate: new Date().toISOString(),
            goalText: 'Zero duration test',
            tags: [],
            durationSeconds: 0,
          });
        expect(res.status).toBe(201);
        expect(res.body.durationSeconds).toBe(0);
      });

      it('should accept omitted durationSeconds (optional field)', async () => {
        const token = await login('student');
        const res = await request(app.server)
          .post('/courses/COURSE_TEST/entries')
          .set('Authorization', `Bearer ${token}`)
          .send({
            id: 'entry-no-dur',
            practiceDate: new Date().toISOString(),
            goalText: 'No duration',
            tags: [],
          });
        expect(res.status).toBe(201);
        expect(res.body.durationSeconds).toBeNull();
      });

      it('should accept omitted tags (defaults to empty array)', async () => {
        const token = await login('student');
        const res = await request(app.server)
          .post('/courses/COURSE_TEST/entries')
          .set('Authorization', `Bearer ${token}`)
          .send({
            id: 'entry-no-tags',
            practiceDate: new Date().toISOString(),
            goalText: 'No tags field',
          });
        expect(res.status).toBe(201);
        expect(res.body.tags).toEqual([]);
      });
    });

    describe('POST /entries/:entryId/submit', () => {
      it('should reject submission when entry has no artifacts', async () => {
        const token = await login('student');
        await prisma.practiceEntry.create({
          data: {
            id: 'entry-no-artifacts',
            courseId: 'COURSE_TEST',
            studentId: 'student-1',
            practiceDate: new Date(),
            goalText: 'No artifacts',
            tags: [],
            status: 'draft',
          },
        });
        const res = await request(app.server)
          .post('/entries/entry-no-artifacts/submit')
          .set('Authorization', `Bearer ${token}`)
          .send();
        expect(res.status).toBe(409);
        expect(res.body.error?.code).toBe('ARTIFACTS_NOT_UPLOADED');
      });

      it('should reject submission when artifacts exist but are not uploaded', async () => {
        const token = await login('student');
        await prisma.practiceEntry.create({
          data: {
            id: 'entry-pending-art',
            courseId: 'COURSE_TEST',
            studentId: 'student-1',
            practiceDate: new Date(),
            goalText: 'Pending artifact',
            tags: [],
            status: 'draft',
          },
        });
        await prisma.artifact.create({
          data: {
            id: 'art-pending',
            entryId: 'entry-pending-art',
            type: 'audio',
            durationSeconds: 60,
            uploadState: 'pending',
          },
        });
        const res = await request(app.server)
          .post('/entries/entry-pending-art/submit')
          .set('Authorization', `Bearer ${token}`)
          .send();
        expect(res.status).toBe(409);
        expect(res.body.error?.code).toBe('ARTIFACTS_NOT_UPLOADED');
      });
    });

    describe('POST /feedback', () => {
      it('should accept feedback with empty markers array', async () => {
        const token = await login('teacher');
        await prisma.practiceEntry.create({
          data: {
            id: 'entry-fb-empty-markers',
            courseId: 'COURSE_TEST',
            studentId: 'student-1',
            practiceDate: new Date(),
            goalText: 'Feedback test',
            tags: [],
            status: 'submitted',
          },
        });
        const res = await request(app.server)
          .post('/feedback')
          .set('Authorization', `Bearer ${token}`)
          .send({
            targetType: 'entry',
            targetId: 'entry-fb-empty-markers',
            status: 'ok',
            commentsText: 'Good work',
            markers: [],
          });
        expect(res.status).toBe(201);
        expect(res.body.markers).toEqual([]);
      });

      it('should accept feedback when markers field is omitted (defaults to empty)', async () => {
        const token = await login('teacher');
        await prisma.practiceEntry.create({
          data: {
            id: 'entry-fb-no-markers',
            courseId: 'COURSE_TEST',
            studentId: 'student-1',
            practiceDate: new Date(),
            goalText: 'Feedback test',
            tags: [],
            status: 'submitted',
          },
        });
        const res = await request(app.server)
          .post('/feedback')
          .set('Authorization', `Bearer ${token}`)
          .send({
            targetType: 'entry',
            targetId: 'entry-fb-no-markers',
            status: 'ok',
            commentsText: 'Looks fine',
          });
        expect(res.status).toBe(201);
        expect(res.body.markers).toEqual([]);
      });

      it('should accept minimal commentsText (single character)', async () => {
        const token = await login('teacher');
        await prisma.practiceEntry.create({
          data: {
            id: 'entry-fb-min-comment',
            courseId: 'COURSE_TEST',
            studentId: 'student-1',
            practiceDate: new Date(),
            goalText: 'Feedback test',
            tags: [],
            status: 'submitted',
          },
        });
        const res = await request(app.server)
          .post('/feedback')
          .set('Authorization', `Bearer ${token}`)
          .send({
            targetType: 'entry',
            targetId: 'entry-fb-min-comment',
            status: 'ok',
            commentsText: 'x',
            markers: [],
          });
        expect(res.status).toBe(201);
        expect(res.body.commentsText).toBe('x');
      });
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // Category 2: Maximum / Boundary Inputs
  // ═══════════════════════════════════════════════════════════════════

  describe('Category 2: Maximum/boundary inputs', () => {
    describe('POST /courses/:courseId/entries', () => {
      it('should accept ID at max length (128 chars)', async () => {
        const token = await login('student');
        const maxId = 'a'.repeat(128);
        const res = await request(app.server)
          .post('/courses/COURSE_TEST/entries')
          .set('Authorization', `Bearer ${token}`)
          .send({
            id: maxId,
            practiceDate: new Date().toISOString(),
            goalText: 'Max ID test',
            tags: [],
          });
        expect(res.status).toBe(201);
        expect(res.body.id).toBe(maxId);
      });

      it('should reject ID exceeding max length (129 chars)', async () => {
        const token = await login('student');
        const tooLongId = 'a'.repeat(129);
        const res = await request(app.server)
          .post('/courses/COURSE_TEST/entries')
          .set('Authorization', `Bearer ${token}`)
          .send({
            id: tooLongId,
            practiceDate: new Date().toISOString(),
            goalText: 'Too long ID',
            tags: [],
          });
        expect(res.status).toBe(400);
        expect(res.body.error?.code).toBe('VALIDATION_ERROR');
      });

      it('should accept tags at max count (30)', async () => {
        const token = await login('student');
        const tags = Array.from({ length: 30 }, (_, i) => `tag-${i}`);
        const res = await request(app.server)
          .post('/courses/COURSE_TEST/entries')
          .set('Authorization', `Bearer ${token}`)
          .send({
            id: 'entry-30-tags',
            practiceDate: new Date().toISOString(),
            goalText: 'Max tags test',
            tags,
          });
        expect(res.status).toBe(201);
        expect(res.body.tags).toHaveLength(30);
      });

      it('should accept goalText at max length (10000 chars)', async () => {
        const token = await login('student');
        const goalText = 'g'.repeat(10000);
        const res = await request(app.server)
          .post('/courses/COURSE_TEST/entries')
          .set('Authorization', `Bearer ${token}`)
          .send({
            id: 'entry-max-goal',
            practiceDate: new Date().toISOString(),
            goalText,
            tags: [],
          });
        expect(res.status).toBe(201);
        expect(res.body.goalText).toHaveLength(10000);
      });

      it('should reject goalText exceeding max length (10001 chars)', async () => {
        const token = await login('student');
        const goalText = 'g'.repeat(10001);
        const res = await request(app.server)
          .post('/courses/COURSE_TEST/entries')
          .set('Authorization', `Bearer ${token}`)
          .send({
            id: 'entry-too-long-goal',
            practiceDate: new Date().toISOString(),
            goalText,
            tags: [],
          });
        expect(res.status).toBe(400);
        expect(res.body.error?.code).toBe('VALIDATION_ERROR');
      });

      it('should accept durationSeconds at max (28800)', async () => {
        const token = await login('student');
        const res = await request(app.server)
          .post('/courses/COURSE_TEST/entries')
          .set('Authorization', `Bearer ${token}`)
          .send({
            id: 'entry-dur-28800',
            practiceDate: new Date().toISOString(),
            goalText: 'Max duration',
            tags: [],
            durationSeconds: 28800,
          });
        expect(res.status).toBe(201);
        expect(res.body.durationSeconds).toBe(28800);
      });

      it('should reject durationSeconds just above max (28801)', async () => {
        const token = await login('student');
        const res = await request(app.server)
          .post('/courses/COURSE_TEST/entries')
          .set('Authorization', `Bearer ${token}`)
          .send({
            id: 'entry-dur-28801',
            practiceDate: new Date().toISOString(),
            goalText: 'Over max duration',
            tags: [],
            durationSeconds: 28801,
          });
        expect(res.status).toBe(400);
        expect(res.body.error?.code).toBe('VALIDATION_ERROR');
      });
    });

    describe('POST /feedback', () => {
      let entryId: string;

      beforeEach(async () => {
        entryId = 'entry-fb-boundary';
        await prisma.practiceEntry.create({
          data: {
            id: entryId,
            courseId: 'COURSE_TEST',
            studentId: 'student-1',
            practiceDate: new Date(),
            goalText: 'Boundary test',
            tags: [],
            status: 'submitted',
          },
        });
      });

      it('should accept marker count at exactly 50', async () => {
        const token = await login('teacher');
        const markers = Array.from({ length: 50 }, (_, i) => ({
          timeSeconds: i * 10,
          text: `Marker ${i}`,
        }));
        const res = await request(app.server)
          .post('/feedback')
          .set('Authorization', `Bearer ${token}`)
          .send({
            targetType: 'entry',
            targetId: entryId,
            status: 'ok',
            commentsText: 'With 50 markers',
            markers,
          });
        expect(res.status).toBe(201);
        expect(res.body.markers).toHaveLength(50);
      });

      it('should reject marker count at 51', async () => {
        const token = await login('teacher');
        const markers = Array.from({ length: 51 }, (_, i) => ({
          timeSeconds: i * 10,
          text: `Marker ${i}`,
        }));
        const res = await request(app.server)
          .post('/feedback')
          .set('Authorization', `Bearer ${token}`)
          .send({
            targetType: 'entry',
            targetId: entryId,
            status: 'ok',
            commentsText: 'With 51 markers',
            markers,
          });
        expect(res.status).toBe(400);
        expect(res.body.error?.code).toBe('VALIDATION_ERROR');
      });

      it('should accept marker timeSeconds at boundary 0', async () => {
        const token = await login('teacher');
        const res = await request(app.server)
          .post('/feedback')
          .set('Authorization', `Bearer ${token}`)
          .send({
            targetType: 'entry',
            targetId: entryId,
            status: 'ok',
            commentsText: 'Boundary marker',
            markers: [{ timeSeconds: 0, text: 'At start' }],
          });
        expect(res.status).toBe(201);
        expect(res.body.markers[0].timeSeconds).toBe(0);
      });

      it('should accept marker timeSeconds at boundary 28800', async () => {
        const token = await login('teacher');
        const res = await request(app.server)
          .post('/feedback')
          .set('Authorization', `Bearer ${token}`)
          .send({
            targetType: 'entry',
            targetId: entryId,
            status: 'ok',
            commentsText: 'Max time marker',
            markers: [{ timeSeconds: 28800, text: 'At max' }],
          });
        expect(res.status).toBe(201);
        expect(res.body.markers[0].timeSeconds).toBe(28800);
      });

      it('should reject marker timeSeconds at 28801', async () => {
        const token = await login('teacher');
        const res = await request(app.server)
          .post('/feedback')
          .set('Authorization', `Bearer ${token}`)
          .send({
            targetType: 'entry',
            targetId: entryId,
            status: 'ok',
            commentsText: 'Over max time marker',
            markers: [{ timeSeconds: 28801, text: 'Over max' }],
          });
        expect(res.status).toBe(400);
        expect(res.body.error?.code).toBe('VALIDATION_ERROR');
      });

      it('should reject negative marker timeSeconds', async () => {
        const token = await login('teacher');
        const res = await request(app.server)
          .post('/feedback')
          .set('Authorization', `Bearer ${token}`)
          .send({
            targetType: 'entry',
            targetId: entryId,
            status: 'ok',
            commentsText: 'Negative time',
            markers: [{ timeSeconds: -1, text: 'Negative' }],
          });
        expect(res.status).toBe(400);
        expect(res.body.error?.code).toBe('VALIDATION_ERROR');
      });

      it('should accept marker text at max length (1000 chars)', async () => {
        const token = await login('teacher');
        const res = await request(app.server)
          .post('/feedback')
          .set('Authorization', `Bearer ${token}`)
          .send({
            targetType: 'entry',
            targetId: entryId,
            status: 'ok',
            commentsText: 'Max marker text',
            markers: [{ timeSeconds: 10, text: 'm'.repeat(1000) }],
          });
        expect(res.status).toBe(201);
        expect(res.body.markers[0].text).toHaveLength(1000);
      });

      it('should accept commentsText at max length (10000 chars)', async () => {
        const token = await login('teacher');
        const res = await request(app.server)
          .post('/feedback')
          .set('Authorization', `Bearer ${token}`)
          .send({
            targetType: 'entry',
            targetId: entryId,
            status: 'ok',
            commentsText: 'c'.repeat(10000),
            markers: [],
          });
        expect(res.status).toBe(201);
        expect(res.body.commentsText).toHaveLength(10000);
      });
    });

    describe('POST /entries/:entryId/artifacts', () => {
      it('should accept artifact ID at max length (128 chars)', async () => {
        const token = await login('student');
        await prisma.practiceEntry.create({
          data: {
            id: 'entry-art-maxid',
            courseId: 'COURSE_TEST',
            studentId: 'student-1',
            practiceDate: new Date(),
            goalText: 'Artifact ID test',
            tags: [],
            status: 'draft',
          },
        });
        const maxId = 'b'.repeat(128);
        const res = await request(app.server)
          .post('/entries/entry-art-maxid/artifacts')
          .set('Authorization', `Bearer ${token}`)
          .send({ id: maxId, type: 'audio', durationSeconds: 60 });
        expect(res.status).toBe(201);
        expect(res.body.id).toBe(maxId);
      });

      it('should accept zero durationSeconds for artifact', async () => {
        const token = await login('student');
        await prisma.practiceEntry.create({
          data: {
            id: 'entry-art-zero-dur',
            courseId: 'COURSE_TEST',
            studentId: 'student-1',
            practiceDate: new Date(),
            goalText: 'Zero dur artifact',
            tags: [],
            status: 'draft',
          },
        });
        const res = await request(app.server)
          .post('/entries/entry-art-zero-dur/artifacts')
          .set('Authorization', `Bearer ${token}`)
          .send({ id: 'art-zero-dur', type: 'audio', durationSeconds: 0 });
        expect(res.status).toBe(201);
        expect(res.body.durationSeconds).toBe(0);
      });
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // Category 3: Unicode and Special Characters
  // ═══════════════════════════════════════════════════════════════════

  describe('Category 3: Unicode and special characters', () => {
    describe('POST /courses/:courseId/entries', () => {
      it('should accept goalText with emoji characters', async () => {
        const token = await login('student');
        const res = await request(app.server)
          .post('/courses/COURSE_TEST/entries')
          .set('Authorization', `Bearer ${token}`)
          .send({
            id: 'entry-emoji-goal',
            practiceDate: new Date().toISOString(),
            goalText: 'Practice scales \u{1F3B5}\u{1F3B6}\u{1F3BB}',
            tags: [],
          });
        expect(res.status).toBe(201);
        expect(res.body.goalText).toContain('\u{1F3B5}');
      });

      it('should accept goalText with RTL text (Arabic)', async () => {
        const token = await login('student');
        const res = await request(app.server)
          .post('/courses/COURSE_TEST/entries')
          .set('Authorization', `Bearer ${token}`)
          .send({
            id: 'entry-rtl-goal',
            practiceDate: new Date().toISOString(),
            goalText:
              '\u0645\u0645\u0627\u0631\u0633\u0629 \u0627\u0644\u0645\u0648\u0633\u064A\u0642\u0649',
            tags: [],
          });
        expect(res.status).toBe(201);
        expect(res.body.goalText).toBe(
          '\u0645\u0645\u0627\u0631\u0633\u0629 \u0627\u0644\u0645\u0648\u0633\u064A\u0642\u0649'
        );
      });

      it('should accept goalText with CJK characters', async () => {
        const token = await login('student');
        const res = await request(app.server)
          .post('/courses/COURSE_TEST/entries')
          .set('Authorization', `Bearer ${token}`)
          .send({
            id: 'entry-cjk-goal',
            practiceDate: new Date().toISOString(),
            goalText: '\u97F3\u697D\u306E\u7DF4\u7FD2',
            tags: [],
          });
        expect(res.status).toBe(201);
        expect(res.body.goalText).toBe('\u97F3\u697D\u306E\u7DF4\u7FD2');
      });

      it('should accept tags with unicode characters', async () => {
        const token = await login('student');
        const res = await request(app.server)
          .post('/courses/COURSE_TEST/entries')
          .set('Authorization', `Bearer ${token}`)
          .send({
            id: 'entry-unicode-tags',
            practiceDate: new Date().toISOString(),
            goalText: 'Unicode tags',
            tags: ['\u00FCbung', 'caf\u00E9', '\u97F3\u697D'],
          });
        expect(res.status).toBe(201);
        expect(res.body.tags).toContain('\u00FCbung');
        expect(res.body.tags).toContain('caf\u00E9');
      });

      it('should accept notes with mixed unicode and newlines', async () => {
        const token = await login('student');
        const res = await request(app.server)
          .post('/courses/COURSE_TEST/entries')
          .set('Authorization', `Bearer ${token}`)
          .send({
            id: 'entry-unicode-notes',
            practiceDate: new Date().toISOString(),
            goalText: 'Notes test',
            tags: [],
            notes: 'Line 1\nLine 2 \u{1F3B5}\nLine 3 \u00E4\u00F6\u00FC',
          });
        expect(res.status).toBe(201);
        expect(res.body.notes).toContain('\n');
        expect(res.body.notes).toContain('\u{1F3B5}');
      });

      it('should reject ID with special characters (only alphanumeric, hyphen, underscore allowed)', async () => {
        const token = await login('student');
        const specialIds = [
          'entry/slash',
          'entry..dots',
          'entry@at',
          'entry space',
          'entry\u00E4uml',
        ];
        for (const id of specialIds) {
          const res = await request(app.server)
            .post('/courses/COURSE_TEST/entries')
            .set('Authorization', `Bearer ${token}`)
            .send({
              id,
              practiceDate: new Date().toISOString(),
              goalText: 'Bad ID',
              tags: [],
            });
          expect(res.status).toBe(400);
          expect(res.body.error?.code).toBe('VALIDATION_ERROR');
        }
      });
    });

    describe('POST /feedback', () => {
      it('should accept commentsText with emoji and special unicode', async () => {
        const token = await login('teacher');
        await prisma.practiceEntry.create({
          data: {
            id: 'entry-fb-unicode',
            courseId: 'COURSE_TEST',
            studentId: 'student-1',
            practiceDate: new Date(),
            goalText: 'FB unicode test',
            tags: [],
            status: 'submitted',
          },
        });
        const res = await request(app.server)
          .post('/feedback')
          .set('Authorization', `Bearer ${token}`)
          .send({
            targetType: 'entry',
            targetId: 'entry-fb-unicode',
            status: 'ok',
            commentsText: 'Great work! \u{1F44D}\u{1F3FB} Keep it up \u{1F3B6}',
            markers: [
              { timeSeconds: 5, text: '\u{1F3B5} Beautiful tone here \u2014 tr\u00E8s bien!' },
            ],
          });
        expect(res.status).toBe(201);
        expect(res.body.commentsText).toContain('\u{1F44D}');
        expect(res.body.markers[0].text).toContain('\u{1F3B5}');
      });
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // Category 4: Missing / Deleted References
  // ═══════════════════════════════════════════════════════════════════

  describe('Category 4: Missing/deleted references', () => {
    describe('POST /feedback', () => {
      it('should return 404 when targeting a non-existent entry ID', async () => {
        const token = await login('teacher');
        const res = await request(app.server)
          .post('/feedback')
          .set('Authorization', `Bearer ${token}`)
          .send({
            targetType: 'entry',
            targetId: 'non-existent-entry-id',
            status: 'ok',
            commentsText: 'Feedback on nothing',
            markers: [],
          });
        expect(res.status).toBe(404);
        expect(res.body.error?.code).toBe('ENTRY_NOT_FOUND');
      });

      it('should return 404 when targeting a non-existent artifact ID', async () => {
        const token = await login('teacher');
        const res = await request(app.server)
          .post('/feedback')
          .set('Authorization', `Bearer ${token}`)
          .send({
            targetType: 'artifact',
            targetId: 'non-existent-artifact-id',
            status: 'ok',
            commentsText: 'Feedback on nothing',
            markers: [],
          });
        expect(res.status).toBe(404);
        expect(res.body.error?.code).toBe('ARTIFACT_NOT_FOUND');
      });

      it('should return 410 when targeting a soft-deleted entry', async () => {
        const token = await login('teacher');
        await prisma.practiceEntry.create({
          data: {
            id: 'entry-deleted-fb',
            courseId: 'COURSE_TEST',
            studentId: 'student-1',
            practiceDate: new Date(),
            goalText: 'Deleted entry',
            tags: [],
            status: 'submitted',
            deletedAt: new Date(),
          },
        });
        const res = await request(app.server)
          .post('/feedback')
          .set('Authorization', `Bearer ${token}`)
          .send({
            targetType: 'entry',
            targetId: 'entry-deleted-fb',
            status: 'ok',
            commentsText: 'Feedback on deleted',
            markers: [],
          });
        expect(res.status).toBe(410);
        expect(res.body.error?.code).toBe('ENTRY_DELETED');
      });

      it('should return 409 when targeting a draft entry (not yet submitted)', async () => {
        const token = await login('teacher');
        await prisma.practiceEntry.create({
          data: {
            id: 'entry-draft-fb',
            courseId: 'COURSE_TEST',
            studentId: 'student-1',
            practiceDate: new Date(),
            goalText: 'Still draft',
            tags: [],
            status: 'draft',
          },
        });
        const res = await request(app.server)
          .post('/feedback')
          .set('Authorization', `Bearer ${token}`)
          .send({
            targetType: 'entry',
            targetId: 'entry-draft-fb',
            status: 'ok',
            commentsText: 'Too early',
            markers: [],
          });
        expect(res.status).toBe(409);
        expect(res.body.error?.code).toBe('ENTRY_NOT_SUBMITTED');
      });
    });

    describe('POST /artifacts/:artifactId/presign', () => {
      it('should return 404 when presigning for a non-existent artifact', async () => {
        const token = await login('student');
        const res = await request(app.server)
          .post('/artifacts/non-existent-artifact/presign')
          .set('Authorization', `Bearer ${token}`)
          .send();
        expect(res.status).toBe(404);
        expect(res.body.error?.code).toBe('ARTIFACT_NOT_FOUND');
      });

      it('should return 410 when presigning for an artifact whose entry was deleted', async () => {
        const token = await login('student');
        await prisma.practiceEntry.create({
          data: {
            id: 'entry-del-presign',
            courseId: 'COURSE_TEST',
            studentId: 'student-1',
            practiceDate: new Date(),
            goalText: 'Deleted entry',
            tags: [],
            status: 'draft',
            deletedAt: new Date(),
          },
        });
        await prisma.artifact.create({
          data: {
            id: 'art-orphaned',
            entryId: 'entry-del-presign',
            type: 'audio',
            durationSeconds: 60,
          },
        });
        const res = await request(app.server)
          .post('/artifacts/art-orphaned/presign')
          .set('Authorization', `Bearer ${token}`)
          .send();
        expect(res.status).toBe(410);
        expect(res.body.error?.code).toBe('ENTRY_DELETED');
      });
    });

    describe('POST /entries/:entryId/artifacts', () => {
      it('should return 404 when creating artifact for a non-existent entry', async () => {
        const token = await login('student');
        const res = await request(app.server)
          .post('/entries/does-not-exist/artifacts')
          .set('Authorization', `Bearer ${token}`)
          .send({ id: 'art-no-entry', type: 'audio', durationSeconds: 60 });
        expect(res.status).toBe(404);
        expect(res.body.error?.code).toBe('ENTRY_NOT_FOUND');
      });

      it('should return 404 when creating artifact for a deleted entry', async () => {
        const token = await login('student');
        await prisma.practiceEntry.create({
          data: {
            id: 'entry-deleted-art',
            courseId: 'COURSE_TEST',
            studentId: 'student-1',
            practiceDate: new Date(),
            goalText: 'Deleted entry artifact',
            tags: [],
            status: 'draft',
            deletedAt: new Date(),
          },
        });
        const res = await request(app.server)
          .post('/entries/entry-deleted-art/artifacts')
          .set('Authorization', `Bearer ${token}`)
          .send({ id: 'art-for-deleted', type: 'audio', durationSeconds: 60 });
        expect(res.status).toBe(404);
        expect(res.body.error?.code).toBe('ENTRY_NOT_FOUND');
      });
    });

    describe('PATCH /entries/:entryId', () => {
      it('should return 404 when patching a non-existent entry', async () => {
        const token = await login('student');
        const res = await request(app.server)
          .patch('/entries/does-not-exist')
          .set('Authorization', `Bearer ${token}`)
          .send({ goalText: 'Updated' });
        expect(res.status).toBe(404);
        expect(res.body.error?.code).toBe('ENTRY_NOT_FOUND');
      });

      it('should return 410 when patching a deleted entry', async () => {
        const token = await login('student');
        await prisma.practiceEntry.create({
          data: {
            id: 'entry-deleted-patch',
            courseId: 'COURSE_TEST',
            studentId: 'student-1',
            practiceDate: new Date(),
            goalText: 'Will be deleted',
            tags: [],
            status: 'draft',
            deletedAt: new Date(),
          },
        });
        const res = await request(app.server)
          .patch('/entries/entry-deleted-patch')
          .set('Authorization', `Bearer ${token}`)
          .send({ goalText: 'Updated' });
        expect(res.status).toBe(410);
        expect(res.body.error?.code).toBe('ENTRY_DELETED');
      });
    });

    describe('DELETE /entries/:entryId', () => {
      it('should return 404 when deleting a non-existent entry', async () => {
        const token = await login('student');
        const res = await request(app.server)
          .delete('/entries/does-not-exist')
          .set('Authorization', `Bearer ${token}`)
          .send();
        expect(res.status).toBe(404);
        expect(res.body.error?.code).toBe('ENTRY_NOT_FOUND');
      });
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // Category 5: State Transitions
  // ═══════════════════════════════════════════════════════════════════

  describe('Category 5: State transitions', () => {
    describe('POST /entries/:entryId/submit', () => {
      it('should reject re-submitting an already submitted entry', async () => {
        const token = await login('student');
        await prisma.practiceEntry.create({
          data: {
            id: 'entry-already-submitted',
            courseId: 'COURSE_TEST',
            studentId: 'student-1',
            practiceDate: new Date(),
            goalText: 'Already submitted',
            tags: [],
            status: 'submitted',
          },
        });
        const res = await request(app.server)
          .post('/entries/entry-already-submitted/submit')
          .set('Authorization', `Bearer ${token}`)
          .send();
        expect(res.status).toBe(409);
        expect(res.body.error?.code).toBe('ENTRY_LOCKED');
      });

      it('should reject submitting an already reviewed entry', async () => {
        const token = await login('student');
        await prisma.practiceEntry.create({
          data: {
            id: 'entry-already-reviewed',
            courseId: 'COURSE_TEST',
            studentId: 'student-1',
            practiceDate: new Date(),
            goalText: 'Already reviewed',
            tags: [],
            status: 'reviewed',
          },
        });
        const res = await request(app.server)
          .post('/entries/entry-already-reviewed/submit')
          .set('Authorization', `Bearer ${token}`)
          .send();
        expect(res.status).toBe(409);
        expect(res.body.error?.code).toBe('ENTRY_LOCKED');
      });
    });

    describe('PATCH /entries/:entryId (submitted/reviewed)', () => {
      it('should reject editing a submitted entry', async () => {
        const token = await login('student');
        await prisma.practiceEntry.create({
          data: {
            id: 'entry-edit-submitted',
            courseId: 'COURSE_TEST',
            studentId: 'student-1',
            practiceDate: new Date(),
            goalText: 'Submitted',
            tags: [],
            status: 'submitted',
          },
        });
        const res = await request(app.server)
          .patch('/entries/entry-edit-submitted')
          .set('Authorization', `Bearer ${token}`)
          .send({ goalText: 'Changed' });
        expect(res.status).toBe(409);
        expect(res.body.error?.code).toBe('ENTRY_LOCKED');
      });

      it('should reject editing a reviewed entry', async () => {
        const token = await login('student');
        await prisma.practiceEntry.create({
          data: {
            id: 'entry-edit-reviewed',
            courseId: 'COURSE_TEST',
            studentId: 'student-1',
            practiceDate: new Date(),
            goalText: 'Reviewed',
            tags: [],
            status: 'reviewed',
          },
        });
        const res = await request(app.server)
          .patch('/entries/entry-edit-reviewed')
          .set('Authorization', `Bearer ${token}`)
          .send({ goalText: 'Changed' });
        expect(res.status).toBe(409);
        expect(res.body.error?.code).toBe('ENTRY_LOCKED');
      });

      it('should allow empty PATCH body on a submitted entry (no restricted fields)', async () => {
        const token = await login('student');
        await prisma.practiceEntry.create({
          data: {
            id: 'entry-empty-patch-submitted',
            courseId: 'COURSE_TEST',
            studentId: 'student-1',
            practiceDate: new Date(),
            goalText: 'Submitted',
            tags: [],
            status: 'submitted',
          },
        });
        const res = await request(app.server)
          .patch('/entries/entry-empty-patch-submitted')
          .set('Authorization', `Bearer ${token}`)
          .send({});
        expect(res.status).toBe(200);
      });
    });

    describe('POST /feedback (on reviewed entry)', () => {
      it('should allow posting additional feedback on a reviewed entry', async () => {
        const token = await login('teacher');
        await prisma.practiceEntry.create({
          data: {
            id: 'entry-reviewed-fb',
            courseId: 'COURSE_TEST',
            studentId: 'student-1',
            practiceDate: new Date(),
            goalText: 'Reviewed entry',
            tags: [],
            status: 'reviewed',
          },
        });
        const res = await request(app.server)
          .post('/feedback')
          .set('Authorization', `Bearer ${token}`)
          .send({
            targetType: 'entry',
            targetId: 'entry-reviewed-fb',
            status: 'needs_revision',
            commentsText: 'Additional feedback',
            markers: [],
          });
        // Entry is in 'reviewed' state (not 'draft'), so feedback should be allowed
        expect(res.status).toBe(201);
        expect(res.body.commentsText).toBe('Additional feedback');
      });

      it('should set entry status to reviewed after feedback', async () => {
        const token = await login('teacher');
        await prisma.practiceEntry.create({
          data: {
            id: 'entry-status-after-fb',
            courseId: 'COURSE_TEST',
            studentId: 'student-1',
            practiceDate: new Date(),
            goalText: 'Status after feedback',
            tags: [],
            status: 'submitted',
          },
        });
        await request(app.server).post('/feedback').set('Authorization', `Bearer ${token}`).send({
          targetType: 'entry',
          targetId: 'entry-status-after-fb',
          status: 'ok',
          commentsText: 'Reviewed!',
          markers: [],
        });
        const entry = await prisma.practiceEntry.findUnique({
          where: { id: 'entry-status-after-fb' },
        });
        expect(entry?.status).toBe('reviewed');
      });
    });

    describe('ID conflicts', () => {
      it('should return 409 when creating an entry with a duplicate ID', async () => {
        const token = await login('student');
        await prisma.practiceEntry.create({
          data: {
            id: 'duplicate-entry',
            courseId: 'COURSE_TEST',
            studentId: 'student-1',
            practiceDate: new Date(),
            goalText: 'Original',
            tags: [],
            status: 'draft',
          },
        });
        const res = await request(app.server)
          .post('/courses/COURSE_TEST/entries')
          .set('Authorization', `Bearer ${token}`)
          .send({
            id: 'duplicate-entry',
            practiceDate: new Date().toISOString(),
            goalText: 'Duplicate',
            tags: [],
          });
        expect(res.status).toBe(409);
        expect(res.body.error?.code).toBe('ID_CONFLICT');
      });

      it('should return 409 when creating an artifact with a duplicate ID', async () => {
        const token = await login('student');
        await prisma.practiceEntry.create({
          data: {
            id: 'entry-dup-art',
            courseId: 'COURSE_TEST',
            studentId: 'student-1',
            practiceDate: new Date(),
            goalText: 'Dup artifact',
            tags: [],
            status: 'draft',
          },
        });
        await prisma.artifact.create({
          data: {
            id: 'duplicate-artifact',
            entryId: 'entry-dup-art',
            type: 'audio',
            durationSeconds: 60,
          },
        });
        const res = await request(app.server)
          .post('/entries/entry-dup-art/artifacts')
          .set('Authorization', `Bearer ${token}`)
          .send({ id: 'duplicate-artifact', type: 'video', durationSeconds: 120 });
        expect(res.status).toBe(409);
        expect(res.body.error?.code).toBe('ID_CONFLICT');
      });
    });
  });
});
