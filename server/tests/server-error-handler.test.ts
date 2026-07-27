// Verifies the process-level error handler returns safe responses without leaking internals.
import { PrismaClient } from '@prisma/client';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { buildServer } from '../src/server.js';

/**
 * Tests for the generic error handler fallthrough in server.ts (lines 155-168).
 * These test the paths where non-ApiError, non-CTP, non-429 errors reach
 * the error handler, including both the 5xx (>=500) and 4xx (<500) branches.
 *
 * A dedicated Fastify instance is used so we can register test routes
 * BEFORE calling app.ready().
 */
describe('server generic error handler', () => {
  let testApp: ReturnType<typeof buildServer>;
  let testPrisma: PrismaClient;

  beforeAll(async () => {
    testPrisma = new PrismaClient();
    testApp = buildServer(testPrisma, {} as any);

    // Register test routes that throw non-ApiError errors BEFORE app.ready()
    testApp.get('/test-500-error', async () => {
      throw new Error('unexpected crash');
    });

    testApp.get('/test-4xx-error', async () => {
      const err = new Error('Custom client error') as Error & { statusCode: number };
      err.statusCode = 422;
      throw err;
    });

    testApp.get('/test-4xx-no-message', async () => {
      const err = Object.assign(new Error(''), { statusCode: 418 });
      // Clear the message to test the `|| 'Bad request'` fallback
      err.message = '';
      throw err;
    });

    await testApp.ready();
  });

  afterAll(async () => {
    await testApp.close();
    await testPrisma.$disconnect();
  });

  it('returns 500 INTERNAL_ERROR for a plain Error thrown in a route', async () => {
    const res = await testApp.inject({
      method: 'GET',
      url: '/test-500-error',
    });
    expect(res.statusCode).toBe(500);
    const body = res.json();
    expect(body.error.code).toBe('INTERNAL_ERROR');
    expect(body.error.message).toBe('Unexpected error');
    // Should not leak the actual error message
    expect(body.error.message).not.toContain('unexpected crash');
  });

  it('returns 4xx with the error message for non-ApiError with statusCode < 500', async () => {
    const res = await testApp.inject({
      method: 'GET',
      url: '/test-4xx-error',
    });
    expect(res.statusCode).toBe(422);
    const body = res.json();
    expect(body.error.code).toBe('VALIDATION_ERROR');
    expect(body.error.message).toBe('Custom client error');
  });

  it('returns 4xx with "Bad request" fallback when error message is empty', async () => {
    const res = await testApp.inject({
      method: 'GET',
      url: '/test-4xx-no-message',
    });
    expect(res.statusCode).toBe(418);
    const body = res.json();
    expect(body.error.code).toBe('VALIDATION_ERROR');
    expect(body.error.message).toBe('Bad request');
  });
});
