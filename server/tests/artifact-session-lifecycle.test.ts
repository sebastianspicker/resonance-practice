// The supported upload path allocates, finalizes to an immutable key, and never reissues a PUT credential.
import { CopyObjectCommand } from '@aws-sdk/client-s3';
import { describe, expect, it } from 'vitest';
import {
  completeSession,
  createSession,
  mockStagedObject,
  sessionPayload,
} from './support/artifactUpload.js';
import { installBasicSuite, login, prisma, s3Mock } from './support/testUtils.js';
import { seedEntry } from './v1-sync/support.js';

describe('artifact-session lifecycle', () => {
  installBasicSuite({ resetS3: true });

  it('allocates once, finalizes to a claim-specific key, and never reissues a completed credential', async () => {
    await seedEntry('upload-entry', 'student-1');
    const token = await login('student');
    const payload = sessionPayload();
    const created = await createSession(token, payload);
    expect(created.status).toBe(200);
    expect(JSON.stringify(created.body)).not.toContain('storageKey');
    const staged = await prisma.artifact.findUniqueOrThrow({ where: { id: 'upload-artifact' } });
    expect(staged.storageKey).toMatch(/^artifacts\/staging\//);
    const stagedSession = await prisma.artifactUploadSession.findUniqueOrThrow({
      where: { id: created.body.sessionId },
    });
    expect(stagedSession.storageKey).toBe(staged.storageKey);

    mockStagedObject();
    const completed = await completeSession(token, created.body.sessionId);
    const replay = await createSession(token, payload);

    expect(completed.status).toBe(200);
    expect(JSON.stringify(completed.body)).not.toContain('storageKey');
    const finalized = await prisma.artifact.findUniqueOrThrow({ where: { id: 'upload-artifact' } });
    expect(finalized.storageKey).toMatch(/^artifacts\/final\/upload-entry\/upload-artifact-/);
    expect(finalized.storageKey).not.toBe(staged.storageKey);
    expect(finalized.uploadState).toBe('uploaded');
    const finalSession = await prisma.artifactUploadSession.findUniqueOrThrow({
      where: { id: created.body.sessionId },
    });
    expect(finalSession.completionFinalKey).toBe(finalized.storageKey);
    expect(finalSession.completedAt).not.toBeNull();
    expect(s3Mock.commandCalls(CopyObjectCommand)).toHaveLength(1);
    expect(replay.body).toMatchObject({ completed: true, uploadUrl: null, requiredHeaders: null });
  });

  it('maps exhausted per-entry and per-user session quotas to RATE_LIMITED before admission', async () => {
    const token = await login('student');
    const allocate = async (entryId: string, index: number, baseVersion: number) =>
      createSession(
        token,
        sessionPayload({
          entryId,
          baseVersion,
          operationId: `${entryId}-op-${index}`,
          artifactId: `${entryId}-artifact-${index}`,
        })
      );
    for (const entryId of ['quota-1', 'quota-2', 'quota-3']) {
      await seedEntry(entryId, 'student-1');
      for (let index = 0; index < 8; index += 1) {
        expect((await allocate(entryId, index, index + 1)).status).toBe(200);
      }
    }
    const perEntry = await allocate('quota-1', 8, 9);
    expect(perEntry.status).toBe(429);
    expect(perEntry.body.error.code).toBe('RATE_LIMITED');

    await seedEntry('quota-4', 'student-1');
    const perUser = await allocate('quota-4', 0, 1);
    expect(perUser.status).toBe(429);
    expect(perUser.body.error.code).toBe('RATE_LIMITED');
    expect(await prisma.artifact.count({ where: { id: { startsWith: 'quota-4' } } })).toBe(0);
  });
});
