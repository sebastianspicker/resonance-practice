// Verifies Unicode content is preserved while control characters and malformed input are rejected.
import {
  app,
  describe,
  expect,
  it,
  login,
  prisma,
  request,
  installEdgeCaseSuite,
} from './support/edgeCaseTestHarness.js';

installEdgeCaseSuite();
describe('edge cases', () => {
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
});
