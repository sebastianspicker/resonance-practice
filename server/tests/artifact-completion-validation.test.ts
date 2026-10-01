// Completion must refuse staged objects that differ from the declared artifact.
import { CopyObjectCommand } from '@aws-sdk/client-s3';
import { describe, expect, it } from 'vitest';
import {
  completeSession,
  createSession,
  mockStagedObject,
  sessionPayload,
  uploadChecksum,
} from './support/artifactUpload.js';
import { installBasicSuite, login, prisma, s3Mock } from './support/testUtils.js';
import { seedEntry } from './v1-sync/support.js';

describe('artifact completion validation', () => {
  installBasicSuite({ resetS3: true });

  it.each([
    ['wrong ContentLength', { head: { ContentLength: 127 } }],
    ['wrong ContentType', { head: { ContentType: 'video/mp4' } }],
    ['wrong ChecksumSHA256', { head: { ChecksumSHA256: uploadChecksum.replace('AAAA', 'AAAB') } }],
    ['non-M4A media bytes', { media: Buffer.alloc(128, 7) }],
  ])(
    'rejects %s with 409 UPLOAD_INVALID and leaves the artifact unuploaded',
    async (_name, mocks) => {
      await seedEntry('upload-entry', 'student-1');
      const token = await login('student');
      const created = await createSession(token, sessionPayload());
      expect(created.status).toBe(200);

      mockStagedObject(
        'head' in mocks ? mocks.head : {},
        'media' in mocks ? mocks.media : undefined
      );
      const completed = await completeSession(token, created.body.sessionId);

      expect(completed.status).toBe(409);
      expect(completed.body.error.code).toBe('UPLOAD_INVALID');
      expect(s3Mock.commandCalls(CopyObjectCommand)).toHaveLength(0);
      const artifact = await prisma.artifact.findUniqueOrThrow({
        where: { id: 'upload-artifact' },
      });
      expect(artifact.uploadState).not.toBe('uploaded');
      const session = await prisma.artifactUploadSession.findFirstOrThrow({
        where: { artifactId: 'upload-artifact' },
      });
      expect(session.completedAt).toBeNull();
    }
  );
});
