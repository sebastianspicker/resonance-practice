// Exercises artifact-session lifecycle and race handling with mocked storage and Prisma seams.
import { CopyObjectCommand, HeadObjectCommand, PutObjectCommand } from '@aws-sdk/client-s3';
import type { S3Client } from '@aws-sdk/client-s3';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const getSignedUrlMock = vi.hoisted(() => vi.fn());

vi.mock('@aws-sdk/s3-request-presigner', () => ({
  getSignedUrl: getSignedUrlMock,
}));

import {
  completeArtifactSession,
  createArtifactSession,
} from '../src/services/artifactSessions.js';
import { artifactCompletionClaimLeaseMs } from '../src/services/entryTransaction.js';

const USER_ID = 'student-1';
const ENTRY_ID = 'entry-1';
const ARTIFACT_ID = 'artifact-1';
const SESSION_ID = 'session-1';

function signedUploadUrl(expiresInSeconds: number) {
  const signedAt = new Date().toISOString().replace(/[-:]|\.\d{3}/g, '');
  return `https://signed.example/upload?X-Amz-Date=${signedAt}&X-Amz-Expires=${expiresInSeconds}`;
}

beforeEach(() => {
  getSignedUrlMock.mockImplementation(
    async (_s3: unknown, _command: unknown, options: { expiresIn: number }) =>
      signedUploadUrl(options.expiresIn)
  );
});

afterEach(() => {
  vi.useRealTimers();
  getSignedUrlMock.mockReset();
});

function entryTransactionSeams(entry: { version: number }) {
  return {
    $queryRaw: vi.fn().mockResolvedValue([{ id: ENTRY_ID }]),
    membership: {
      findUnique: vi.fn().mockResolvedValue({ roleInCourse: 'student' }),
    },
    practiceEntry: {
      findUnique: vi.fn().mockImplementation(async () => entry),
      update: vi.fn().mockImplementation(async () => {
        entry.version += 1;
        return entry;
      }),
    },
  };
}

function updateArtifactUploadSession(getSession: () => any, getArtifact: () => any) {
  return vi.fn().mockImplementation(async ({ data }: any) => {
    const session = getSession();
    Object.assign(session, data);
    return { ...session, artifact: getArtifact() };
  });
}

function artifactUploadSessionSeams(
  session: () => any,
  artifact: () => any,
  seams: Record<string, unknown>
) {
  return {
    ...seams,
    findUniqueOrThrow: vi
      .fn()
      .mockImplementation(async () => ({ ...session(), artifact: artifact() })),
    update: updateArtifactUploadSession(session, artifact),
  };
}

function findDeletionJob(deletionJobs: Map<string, { nextAttemptAt: Date }>) {
  return vi.fn().mockImplementation(async ({ where }: any) => {
    return deletionJobs.get(where.storageKey) ?? null;
  });
}

function completionHarness(options: {
  now: Date;
  completionClaimToken?: string | null;
  completionFinalKey?: string | null;
  completionClaimedAt?: Date | null;
}) {
  const entry = {
    id: ENTRY_ID,
    courseId: 'course-1',
    studentId: USER_ID,
    deletedAt: null,
    version: 1,
  };
  const artifact = {
    id: ARTIFACT_ID,
    entryId: ENTRY_ID,
    type: 'audio',
    durationSeconds: 10,
    expectedSizeBytes: 128,
    storageKey: `artifacts/staging/${ENTRY_ID}/${ARTIFACT_ID}`,
    uploadState: 'uploading',
    uploadExpiresAt: new Date(options.now.getTime() + 60_000),
    confirmationToken: null,
    failedAt: null,
  };
  const session = {
    id: SESSION_ID,
    userId: USER_ID,
    operationId: 'operation-1',
    payloadHash: 'hash',
    artifactId: ARTIFACT_ID,
    storageKey: artifact.storageKey,
    expiresAt: new Date(options.now.getTime() + 60_000),
    credentialExpiresAt: new Date(options.now.getTime() + 45_000),
    completedAt: null as Date | null,
    completionClaimToken: options.completionClaimToken ?? null,
    completionFinalKey: options.completionFinalKey ?? null,
    completionClaimedAt: options.completionClaimedAt ?? null,
    artifact,
  };
  const deletionJobs = new Map<string, { nextAttemptAt: Date }>();
  const tx = {
    ...entryTransactionSeams(entry),
    artifact: {
      update: vi.fn().mockImplementation(async ({ data }: any) => {
        Object.assign(artifact, data);
        return artifact;
      }),
      findUniqueOrThrow: vi.fn().mockImplementation(async () => artifact),
    },
    artifactUploadSession: artifactUploadSessionSeams(
      () => session,
      () => artifact,
      {
        findUnique: vi.fn().mockImplementation(async () => ({ ...session, artifact })),
      }
    ),
    storageDeletionJob: {
      findUnique: findDeletionJob(deletionJobs),
      upsert: vi.fn().mockImplementation(async ({ create, update }: any) => {
        const prior = deletionJobs.get(create.storageKey);
        const nextAttemptAt = prior ? update.nextAttemptAt : create.nextAttemptAt;
        deletionJobs.set(create.storageKey, { nextAttemptAt });
        return { storageKey: create.storageKey, nextAttemptAt };
      }),
    },
  };
  const prisma = {
    $transaction: vi.fn(async (operation: (client: typeof tx) => unknown) => operation(tx)),
  } as any;
  return { prisma, session, artifact, deletionJobs };
}

function storageClient(
  head: () => Promise<unknown>,
  copy: () => Promise<unknown> = async () => ({})
) {
  const send = vi.fn(async (command: unknown) => {
    if (command instanceof HeadObjectCommand) return head();
    if (command instanceof CopyObjectCommand) return copy();
    throw new Error(`Unexpected command: ${String(command)}`);
  });
  return { client: { send } as unknown as S3Client, send };
}

describe('artifact completion claims', () => {
  it('lets only the request that creates the claim perform storage I/O', async () => {
    const now = new Date('2026-07-16T09:00:00.000Z');
    vi.useFakeTimers();
    vi.setSystemTime(now);
    const harness = completionHarness({ now });
    let resolveHead!: (value: { ContentLength: number; ETag: string }) => void;
    const pendingHead = new Promise<{ ContentLength: number; ETag: string }>((resolve) => {
      resolveHead = resolve;
    });
    const storage = storageClient(() => pendingHead);

    const first = completeArtifactSession(harness.prisma, storage.client, USER_ID, SESSION_ID);
    await vi.waitFor(() => expect(harness.session.completionClaimToken).not.toBeNull());

    await expect(
      completeArtifactSession(harness.prisma, storage.client, USER_ID, SESSION_ID)
    ).rejects.toMatchObject({
      statusCode: 409,
      code: 'UPLOAD_INVALID',
      message: 'Artifact completion is in progress; retry later',
    });
    expect(storage.send.mock.calls.map(([command]) => command)).toEqual([
      expect.any(HeadObjectCommand),
    ]);

    resolveHead({ ContentLength: 128, ETag: '"etag-1"' });
    await expect(first).resolves.toMatchObject({
      artifact: { uploadState: 'uploaded' },
      currentVersion: 2,
    });
    expect(storage.send.mock.calls.map(([command]) => command)).toEqual([
      expect.any(HeadObjectCommand),
      expect.any(CopyObjectCommand),
    ]);
  });

  it('takes over a stale claim with a new immutable key and queues the old key', async () => {
    const now = new Date('2026-07-16T09:00:00.000Z');
    vi.useFakeTimers();
    vi.setSystemTime(now);
    const oldFinalKey = `artifacts/final/${ENTRY_ID}/${ARTIFACT_ID}-old-claim`;
    const harness = completionHarness({
      now,
      completionClaimToken: 'old-claim',
      completionFinalKey: oldFinalKey,
      completionClaimedAt: new Date(now.getTime() - artifactCompletionClaimLeaseMs() - 1),
    });
    const storage = storageClient(async () => ({ ContentLength: 128, ETag: '"etag-2"' }));

    await expect(
      completeArtifactSession(harness.prisma, storage.client, USER_ID, SESSION_ID)
    ).resolves.toMatchObject({ artifact: { uploadState: 'uploaded' } });

    const copy = storage.send.mock.calls
      .map(([command]) => command)
      .find((command) => command instanceof CopyObjectCommand) as CopyObjectCommand;
    expect(copy.input.Key).toMatch(
      new RegExp(`^artifacts/final/${ENTRY_ID}/${ARTIFACT_ID}-(?!old-claim)`)
    );
    expect(harness.artifact.storageKey).toBe(copy.input.Key);
    expect(harness.deletionJobs.get(oldFinalKey)?.nextAttemptAt.getTime()).toBeGreaterThan(
      now.getTime()
    );
  });

  it('fails closed without an ETag and never copies', async () => {
    const now = new Date('2026-07-16T09:00:00.000Z');
    vi.useFakeTimers();
    vi.setSystemTime(now);
    const harness = completionHarness({ now });
    const storage = storageClient(async () => ({ ContentLength: 128 }));

    await expect(
      completeArtifactSession(harness.prisma, storage.client, USER_ID, SESSION_ID)
    ).rejects.toMatchObject({
      statusCode: 409,
      code: 'UPLOAD_INVALID',
      message: 'Uploaded object is missing a supported integrity validator',
    });
    expect(storage.send).toHaveBeenCalledTimes(1);
    expect(harness.session.completionClaimToken).toBeNull();
    expect(harness.deletionJobs.size).toBe(1);
  });

  it('maps a changed source to 409 and transient copy failures to 503', async () => {
    const now = new Date('2026-07-16T09:00:00.000Z');
    vi.useFakeTimers();
    vi.setSystemTime(now);
    const changed = completionHarness({ now });
    const changedStorage = storageClient(
      async () => ({ ContentLength: 128, ETag: '"etag-before"' }),
      async () => {
        throw Object.assign(new Error('precondition failed'), {
          name: 'PreconditionFailed',
          $metadata: { httpStatusCode: 412 },
        });
      }
    );
    await expect(
      completeArtifactSession(changed.prisma, changedStorage.client, USER_ID, SESSION_ID)
    ).rejects.toMatchObject({ statusCode: 409, code: 'UPLOAD_INVALID' });
    const changedCopy = changedStorage.send.mock.calls[1]![0] as CopyObjectCommand;
    expect(changedCopy.input.CopySourceIfMatch).toBe('"etag-before"');

    const transient = completionHarness({ now });
    const transientStorage = storageClient(
      async () => ({ ContentLength: 128, ETag: '"etag-3"' }),
      async () => {
        throw new Error('socket reset');
      }
    );
    await expect(
      completeArtifactSession(transient.prisma, transientStorage.client, USER_ID, SESSION_ID)
    ).rejects.toMatchObject({ statusCode: 503, code: 'STORAGE_UNAVAILABLE' });
  });
});

function createSessionHarness(start: Date, advanceBeforeSigningMs: number) {
  const entry = {
    id: ENTRY_ID,
    courseId: 'course-1',
    studentId: USER_ID,
    deletedAt: null,
    version: 1,
    status: 'draft',
  };
  let artifact: any = null;
  let session: any = null;
  const deletionJobs = new Map<string, { nextAttemptAt: Date }>();
  const tx = {
    ...entryTransactionSeams(entry),
    artifact: {
      findUnique: vi.fn().mockResolvedValue(null),
      count: vi.fn().mockResolvedValue(0),
      aggregate: vi.fn().mockResolvedValue({
        _count: { _all: 0 },
        _sum: { expectedSizeBytes: 0 },
      }),
      create: vi.fn().mockImplementation(async ({ data }: any) => {
        artifact = { ...data, createdAt: start, remoteUrl: null, failedAt: null };
        return artifact;
      }),
      update: vi.fn().mockImplementation(async ({ data }: any) => {
        Object.assign(artifact, data);
        return artifact;
      }),
    },
    artifactUploadSession: artifactUploadSessionSeams(
      () => session,
      () => artifact,
      {
        findUnique: vi.fn().mockResolvedValue(null),
        count: vi.fn().mockResolvedValue(0),
        create: vi.fn().mockImplementation(async ({ data }: any) => {
          session = {
            id: SESSION_ID,
            ...data,
            credentialExpiresAt: null,
            completedAt: null,
            completionClaimToken: null,
            completionFinalKey: null,
            completionClaimedAt: null,
            artifact,
          };
          return session;
        }),
      }
    ),
    storageDeletionJob: {
      findUnique: findDeletionJob(deletionJobs),
      upsert: vi.fn().mockImplementation(async ({ create }: any) => {
        deletionJobs.set(create.storageKey, { nextAttemptAt: create.nextAttemptAt });
        return create;
      }),
    },
  };
  let transactionCount = 0;
  const prisma = {
    $transaction: vi.fn(async (operation: (client: typeof tx) => unknown) => {
      transactionCount += 1;
      if (transactionCount === 2) {
        vi.setSystemTime(new Date(start.getTime() + advanceBeforeSigningMs));
      }
      return operation(tx);
    }),
  } as any;
  return {
    prisma,
    get session() {
      return session;
    },
    get artifact() {
      return artifact;
    },
    deletionJobs,
  };
}

const createInput = {
  userId: USER_ID,
  operationId: 'operation-1',
  entryId: ENTRY_ID,
  artifactId: ARTIFACT_ID,
  type: 'audio' as const,
  durationSeconds: 10,
  sizeBytes: 128,
  baseVersion: 1,
};

describe('artifact upload credentials and quotas', () => {
  it('signs a retry for only the exact remaining session lifetime', async () => {
    const start = new Date('2026-07-16T09:00:00.000Z');
    vi.useFakeTimers();
    vi.setSystemTime(start);
    const harness = createSessionHarness(start, 893_000);

    const result = await createArtifactSession(
      harness.prisma,
      { send: vi.fn() } as unknown as S3Client,
      createInput
    );

    expect(result.expiresInSeconds).toBe(7);
    expect(getSignedUrlMock).toHaveBeenCalledWith(expect.anything(), expect.any(PutObjectCommand), {
      expiresIn: 7,
    });
    expect(harness.session.credentialExpiresAt).toEqual(new Date(start.getTime() + 900_000));
  });

  it('rotates an insufficient session without shortening old-key cleanup', async () => {
    const start = new Date('2026-07-16T09:00:00.000Z');
    vi.useFakeTimers();
    vi.setSystemTime(start);
    const harness = createSessionHarness(start, 898_000);

    const result = await createArtifactSession(
      harness.prisma,
      { send: vi.fn() } as unknown as S3Client,
      createInput
    );

    expect(result.expiresInSeconds).toBe(900);
    expect(result.artifact.storageKey).not.toBe(`artifacts/staging/${ENTRY_ID}/${ARTIFACT_ID}`);
    const [oldKeyJob] = [...harness.deletionJobs.values()];
    expect(oldKeyJob?.nextAttemptAt).toEqual(new Date(start.getTime() + 1_200_000));
  });

  it('reduces TTL when a delayed signer would outlive the session', async () => {
    const start = new Date('2026-07-16T09:00:00.000Z');
    vi.useFakeTimers();
    vi.setSystemTime(start);
    const harness = createSessionHarness(start, 893_000);
    getSignedUrlMock.mockImplementation(
      async (_s3: unknown, _command: unknown, options: { expiresIn: number }) => {
        vi.advanceTimersByTime(2_000);
        return signedUploadUrl(options.expiresIn);
      }
    );

    const result = await createArtifactSession(
      harness.prisma,
      { send: vi.fn() } as unknown as S3Client,
      createInput
    );

    expect(getSignedUrlMock.mock.calls.map((call) => call[2])).toEqual([
      { expiresIn: 7 },
      { expiresIn: 3 },
    ]);
    expect(result.expiresInSeconds).toBe(3);
    expect(harness.session.credentialExpiresAt).toEqual(new Date(start.getTime() + 900_000));
    expect(harness.session.credentialExpiresAt).toEqual(harness.session.expiresAt);
  });

  it('maps raw signer failures to 503 STORAGE_UNAVAILABLE', async () => {
    const start = new Date('2026-07-16T09:00:00.000Z');
    vi.useFakeTimers();
    vi.setSystemTime(start);
    const harness = createSessionHarness(start, 0);
    getSignedUrlMock.mockRejectedValue(new Error('credential provider failed'));

    await expect(
      createArtifactSession(harness.prisma, { send: vi.fn() } as unknown as S3Client, createInput)
    ).rejects.toMatchObject({
      statusCode: 503,
      code: 'STORAGE_UNAVAILABLE',
      message: 'Storage is temporarily unavailable',
    });
  });

  it('shares one dependency timeout budget across presign retries', async () => {
    const start = new Date('2026-07-16T09:00:00.000Z');
    vi.useFakeTimers();
    vi.setSystemTime(start);
    const harness = createSessionHarness(start, 0);
    getSignedUrlMock
      .mockImplementationOnce(
        async (_s3: unknown, _command: unknown, options: { expiresIn: number }) => {
          vi.advanceTimersByTime(4_000);
          return signedUploadUrl(options.expiresIn);
        }
      )
      .mockImplementationOnce(async () => new Promise<string>(() => {}));

    const pending = createArtifactSession(
      harness.prisma,
      { send: vi.fn() } as unknown as S3Client,
      createInput
    ).catch((error: unknown) => error);
    await vi.advanceTimersByTimeAsync(0);
    expect(getSignedUrlMock.mock.calls.map((call) => call[2])).toEqual([
      { expiresIn: 900 },
      { expiresIn: 892 },
    ]);

    await vi.advanceTimersByTimeAsync(6_000);
    await expect(pending).resolves.toMatchObject({
      statusCode: 503,
      code: 'STORAGE_UNAVAILABLE',
      message: 'Storage is temporarily unavailable',
    });
    expect(Date.now()).toBe(start.getTime() + 10_000);
  });

  it('serializes concurrent durable quota admission so only one final slot is accepted', async () => {
    const start = new Date('2026-07-16T09:00:00.000Z');
    vi.useFakeTimers();
    vi.setSystemTime(start);
    const entries = new Map([
      [
        'entry-a',
        {
          id: 'entry-a',
          courseId: 'course-1',
          studentId: USER_ID,
          deletedAt: null,
          version: 1,
          status: 'draft',
        },
      ],
      [
        'entry-b',
        {
          id: 'entry-b',
          courseId: 'course-1',
          studentId: USER_ID,
          deletedAt: null,
          version: 1,
          status: 'draft',
        },
      ],
    ]);
    const artifacts = new Map<string, any>();
    const sessions = new Map<string, any>();
    let durableCount = 499;
    let quotaLocked = false;
    const quotaWaiters: Array<() => void> = [];
    const acquireQuota = async () => {
      if (!quotaLocked) {
        quotaLocked = true;
        return;
      }
      await new Promise<void>((resolve) => quotaWaiters.push(resolve));
    };
    const releaseQuota = () => {
      const next = quotaWaiters.shift();
      if (next) next();
      else quotaLocked = false;
    };
    const makeTransaction = () => {
      let releaseHeldQuota = false;
      const tx = {
        $queryRaw: vi.fn(async (strings: TemplateStringsArray, ...values: unknown[]) => {
          const sql = strings.join('');
          if (sql.includes('hashtextextended(, 3)')) {
            await acquireQuota();
            releaseHeldQuota = true;
          }
          if (sql.includes('FOR UPDATE')) return [{ id: values[0] }];
          return [{ locked: '1' }];
        }),
        membership: {
          findUnique: vi.fn().mockResolvedValue({ roleInCourse: 'student' }),
        },
        practiceEntry: {
          findUnique: vi.fn().mockImplementation(async ({ where }: any) => entries.get(where.id)),
          update: vi.fn().mockImplementation(async ({ where }: any) => {
            const entry = entries.get(where.id)!;
            entry.version += 1;
            return entry;
          }),
        },
        artifact: {
          findUnique: vi.fn().mockImplementation(async ({ where }: any) => artifacts.get(where.id)),
          count: vi.fn().mockResolvedValue(0),
          aggregate: vi.fn().mockImplementation(async () => ({
            _count: { _all: durableCount },
            _sum: { expectedSizeBytes: durableCount * 128 },
          })),
          create: vi.fn().mockImplementation(async ({ data }: any) => {
            const artifact = {
              ...data,
              createdAt: start,
              remoteUrl: null,
              failedAt: null,
            };
            artifacts.set(data.id, artifact);
            durableCount += 1;
            return artifact;
          }),
          update: vi.fn().mockImplementation(async ({ where, data }: any) => {
            const artifact = artifacts.get(where.id);
            Object.assign(artifact, data);
            return artifact;
          }),
        },
        artifactUploadSession: {
          findUnique: vi.fn().mockImplementation(async ({ where }: any) => {
            if (!where.userId_operationId) return null;
            return [...sessions.values()].find(
              (session) =>
                session.userId === where.userId_operationId.userId &&
                session.operationId === where.userId_operationId.operationId
            );
          }),
          count: vi.fn().mockResolvedValue(0),
          create: vi.fn().mockImplementation(async ({ data }: any) => {
            const session = {
              id: `session-${data.operationId}`,
              ...data,
              credentialExpiresAt: null,
              completedAt: null,
              completionClaimToken: null,
              completionFinalKey: null,
              completionClaimedAt: null,
            };
            sessions.set(session.id, session);
            return session;
          }),
          findUniqueOrThrow: vi.fn().mockImplementation(async ({ where }: any) => {
            const session = sessions.get(where.id);
            return { ...session, artifact: artifacts.get(session.artifactId) };
          }),
          update: vi.fn().mockImplementation(async ({ where, data }: any) => {
            const session = sessions.get(where.id);
            Object.assign(session, data);
            return { ...session, artifact: artifacts.get(session.artifactId) };
          }),
        },
        storageDeletionJob: {
          findUnique: vi.fn().mockResolvedValue(null),
          upsert: vi.fn(),
        },
      };
      return {
        tx,
        release: () => {
          if (releaseHeldQuota) releaseQuota();
        },
      };
    };
    const prisma = {
      $transaction: vi.fn(async (operation: (client: any) => unknown) => {
        const transaction = makeTransaction();
        try {
          return await operation(transaction.tx);
        } finally {
          transaction.release();
        }
      }),
    } as any;
    const s3 = { send: vi.fn() } as unknown as S3Client;
    const results = await Promise.allSettled([
      createArtifactSession(prisma, s3, {
        ...createInput,
        operationId: 'operation-a',
        entryId: 'entry-a',
        artifactId: 'artifact-a',
      }),
      createArtifactSession(prisma, s3, {
        ...createInput,
        operationId: 'operation-b',
        entryId: 'entry-b',
        artifactId: 'artifact-b',
      }),
    ]);

    expect(results.filter((result) => result.status === 'fulfilled')).toHaveLength(1);
    const rejected = results.find((result) => result.status === 'rejected');
    expect(rejected).toMatchObject({
      reason: { statusCode: 429, code: 'RATE_LIMITED' },
    });
    expect(durableCount).toBe(500);
  });
});
