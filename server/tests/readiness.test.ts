// Verifies readiness coalesces dependency probes and fails closed on database or storage errors.
import { HeadBucketCommand, S3Client } from '@aws-sdk/client-s3';
import { mockClient } from 'aws-sdk-client-mock';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { buildServer } from '../src/server.js';

const s3Mock = mockClient(S3Client);
const apps: Array<ReturnType<typeof buildServer>> = [];

function createReadinessApp(prisma: object) {
  const app = buildServer(prisma as any, new S3Client({}));
  apps.push(app);
  return app;
}

describe('service readiness', () => {
  beforeEach(() => {
    s3Mock.reset();
  });

  afterEach(async () => {
    await Promise.all(apps.splice(0).map((app) => app.close()));
  });

  it('reports ready only when PostgreSQL and object storage respond', async () => {
    const prisma = { $queryRaw: vi.fn().mockResolvedValue([{ '?column?': 1 }]) } as any;
    s3Mock.on(HeadBucketCommand).resolves({});
    const app = createReadinessApp(prisma);

    const response = await app.inject({ method: 'GET', url: '/ready' });

    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({ status: 'ready' });
    expect(prisma.$queryRaw).toHaveBeenCalledOnce();
  });

  it('returns 503 when PostgreSQL is unavailable while liveness stays healthy', async () => {
    const prisma = {
      $queryRaw: vi.fn().mockRejectedValue(new Error('database unavailable')),
    } as any;
    s3Mock.on(HeadBucketCommand).resolves({});
    const app = createReadinessApp(prisma);

    const readiness = await app.inject({ method: 'GET', url: '/ready' });
    const liveness = await app.inject({ method: 'GET', url: '/health' });

    expect(readiness.statusCode).toBe(503);
    expect(readiness.json()).toEqual({ status: 'unavailable' });
    expect(liveness.statusCode).toBe(200);
    expect(liveness.json()).toEqual({ status: 'ok' });
  });

  it('returns 503 when object storage is unavailable', async () => {
    const prisma = { $queryRaw: vi.fn().mockResolvedValue([{ '?column?': 1 }]) } as any;
    s3Mock.on(HeadBucketCommand).rejects(new Error('storage unavailable'));
    const app = createReadinessApp(prisma);

    const response = await app.inject({ method: 'GET', url: '/ready' });

    expect(response.statusCode).toBe(503);
    expect(response.json()).toEqual({ status: 'unavailable' });
  });
});
