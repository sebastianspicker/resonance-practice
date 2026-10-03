import { afterEach, describe, expect, it } from 'vitest';
import { createApiApp, registerStatusRoutes, registerTransport } from '../src/app/serverRuntime.js';
import {
  collectPageWithinByteBudget,
  fitPageToByteBudget,
  MAX_ENTRY_ROWS_PER_FETCH,
} from '../src/platform/http/pagination.js';

describe('security hardening', () => {
  const apps: ReturnType<typeof createApiApp>[] = [];

  afterEach(async () => {
    await Promise.all(apps.splice(0).map((app) => app.close()));
  });

  it('rate-limits readiness probes without limiting health checks', async () => {
    const app = createApiApp();
    apps.push(app);
    registerTransport(app);
    let dependencyChecks = 0;
    app.after(() => {
      registerStatusRoutes(app, async () => {
        dependencyChecks += 1;
      });
    });
    await app.ready();

    const inject = (method: 'GET' | 'HEAD', url: string) =>
      app.inject({ method, url, remoteAddress: '203.0.113.10' });

    expect((await inject('GET', '/ready?probe=first')).statusCode).toBe(200);
    for (let request = 1; request < 100; request += 1) {
      expect((await inject('GET', '/ready')).statusCode).toBe(200);
    }
    expect(dependencyChecks).toBe(100);

    const limited = await inject('GET', '/ready?probe=limited');
    expect(limited.statusCode).toBe(429);
    expect(limited.json().error).toMatchObject({ code: 'RATE_LIMITED' });
    expect((await inject('HEAD', '/ready')).statusCode).toBe(429);
    expect(dependencyChecks).toBe(100);

    expect((await inject('GET', '/health?probe=after-limit')).statusCode).toBe(200);
    expect(dependencyChecks).toBe(100);
  });

  it('fetches nested pages in bounded batches while preserving small-page compatibility', async () => {
    const rows = Array.from({ length: 5 }, (_, index) => ({ id: `entry-${index}` }));
    const takes: number[] = [];
    const page = await collectPageWithinByteBudget(
      undefined,
      4,
      MAX_ENTRY_ROWS_PER_FETCH,
      async (cursor, take) => {
        takes.push(take);
        const start = cursor ? rows.findIndex((row) => row.id === cursor) + 1 : 0;
        return rows.slice(start, start + take);
      },
      (row) => row
    );

    expect(takes).toEqual([2, 2, 1]);
    expect(page).toEqual({ items: rows.slice(0, 4), nextCursor: 'entry-3' });
  });

  it('returns a cursor-safe prefix that fits the serialized byte budget', () => {
    const first = { id: 'entry-1', value: 'a'.repeat(32) };
    const second = { id: 'entry-2', value: 'b'.repeat(32) };
    const oneItemBytes = Buffer.byteLength(
      JSON.stringify({ items: [first], nextCursor: first.id }),
      'utf8'
    );

    const result = fitPageToByteBudget({ items: [first, second], nextCursor: null }, oneItemBytes);

    expect(result).toEqual({ items: [first], nextCursor: first.id });
    expect(Buffer.byteLength(JSON.stringify(result), 'utf8')).toBeLessThanOrEqual(oneItemBytes);
  });

  it('continues a byte-limited collected page without skipping the deferred row', async () => {
    const rows = [
      { id: 'entry-1', value: 'a'.repeat(4 * 1024 * 1024) },
      { id: 'entry-2', value: 'b'.repeat(4 * 1024 * 1024) },
    ];
    const fetchRows = async (cursor: string | undefined, take: number) => {
      const start = cursor ? rows.findIndex((row) => row.id === cursor) + 1 : 0;
      return rows.slice(start, start + take);
    };

    const firstPage = await collectPageWithinByteBudget(
      undefined,
      2,
      MAX_ENTRY_ROWS_PER_FETCH,
      fetchRows,
      (row) => row
    );
    expect(firstPage).toEqual({ items: [rows[0]], nextCursor: 'entry-1' });

    const secondPage = await collectPageWithinByteBudget(
      firstPage.nextCursor ?? undefined,
      2,
      MAX_ENTRY_ROWS_PER_FETCH,
      fetchRows,
      (row) => row
    );
    expect(secondPage).toEqual({ items: [rows[1]], nextCursor: null });
  });

  it('rejects a singleton that cannot fit without truncation', () => {
    expect(() =>
      fitPageToByteBudget({ items: [{ id: 'entry-1', value: 'large' }], nextCursor: null }, 16)
    ).toThrow('A response item exceeds the transport size limit');
  });
});
