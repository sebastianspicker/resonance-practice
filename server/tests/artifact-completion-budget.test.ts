import { CopyObjectCommand, GetObjectCommand, HeadObjectCommand } from '@aws-sdk/client-s3';
import { describe, expect, it } from 'vitest';
import { copyArtifactCompletionClaim } from '../src/modules/media/application/artifactSessions.js';
import type { ArtifactCompletionClaim } from '../src/modules/entries/application/transaction.js';

describe('artifact completion storage budget', () => {
  it('does not start a copy when an ignored-signal body finishes after the deadline', async () => {
    let resolveBody!: (bytes: Uint8Array) => void;
    const body = new Promise<Uint8Array>((resolve) => {
      resolveBody = resolve;
    });
    let copyCalls = 0;
    const s3 = {
      send: async (command: object) => {
        if (command instanceof HeadObjectCommand) {
          return {
            ContentLength: 128,
            ContentType: 'audio/m4a',
            ChecksumSHA256: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
            ETag: '"etag"',
          };
        }
        if (command instanceof GetObjectCommand) {
          return { Body: { transformToByteArray: () => body } };
        }
        if (command instanceof CopyObjectCommand) copyCalls += 1;
        return {};
      },
    };
    const tx = {
      $queryRaw: async () => [{ locked: '1' }],
      artifactUploadSession: {
        findUnique: async () => ({ completionClaimToken: 'claim-token' }),
        update: async () => undefined,
      },
      storageDeletionJob: {
        findUnique: async () => null,
        upsert: async () => undefined,
      },
    };
    const prisma = {
      $transaction: async (operation: (client: typeof tx) => Promise<unknown>) => operation(tx),
    };
    const claim: ArtifactCompletionClaim = {
      token: 'claim-token',
      storageKey: 'artifacts/final/entry/artifact-claim-token',
      stagingKey: 'artifacts/staging/entry/artifact-upload',
      expectedSizeBytes: 128,
      checksumSha256: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
      type: 'audio',
      expiresAt: new Date(Date.now() + 60_000),
      credentialExpiresAt: null,
      claimedAt: new Date(),
      entryId: 'entry',
      artifactId: 'artifact',
    };

    await expect(
      copyArtifactCompletionClaim(prisma as never, s3 as never, 'session', claim, 20)
    ).rejects.toMatchObject({ statusCode: 503, code: 'STORAGE_UNAVAILABLE' });
    resolveBody(new Uint8Array(128));
    await new Promise((resolve) => setImmediate(resolve));
    expect(copyCalls).toBe(0);
  });
});
