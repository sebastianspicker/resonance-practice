import type { S3Client } from '@aws-sdk/client-s3';
import type { PrismaClient } from '@prisma/client';
import { createHash } from 'node:crypto';
import type { FastifyReply } from 'fastify';
import { describe, expect, it, vi } from 'vitest';
import contract from '../../contracts/v1-api-contract.json';
import { buildServer } from '../src/server.js';
import { ErrorCodes } from '../src/platform/http/errorCodes.js';
import { ApiError, sendError } from '../src/platform/http/errors.js';
import { parseSyncCommand } from '../src/modules/sync/application/commands.js';
import { DEFAULT_PAGE_SIZE, MAX_PAGE_SIZE, cursorPage } from '../src/platform/http/pagination.js';

const v1Contract = contract as {
  reads: { pageFields: string[]; defaultPageSize: number; maxPageSize: number };
  routes: Array<{ method: 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE'; path: string }>;
  sync: {
    commandFields: string[];
    commandKinds: string[];
    resultFields: string[];
    resultStatuses: string[];
  };
  artifactSessions: {
    createRequestFields: string[];
    checksumSha256: { encoding: string; decodedByteLength: number };
    createResponseFields: string[];
    completeResponseFields: string[];
    downloadResponseFields: string[];
  };
  errorEnvelope: { fields: string[] };
};

describe('v1 API contract', () => {
  it('keeps bounded read envelopes aligned with the client contract', () => {
    expect(DEFAULT_PAGE_SIZE).toBe(v1Contract.reads.defaultPageSize);
    expect(MAX_PAGE_SIZE).toBe(v1Contract.reads.maxPageSize);
    expect(Object.keys(cursorPage([], DEFAULT_PAGE_SIZE))).toEqual(v1Contract.reads.pageFields);
  });
  it('registers every canonical v1 route with its declared method', async () => {
    const app = buildServer({} as PrismaClient, {} as S3Client);
    try {
      for (const route of v1Contract.routes) {
        expect(app.hasRoute({ method: route.method, url: route.path })).toBe(true);
      }
    } finally {
      await app.close();
    }
  });

  it('accepts every declared sync command kind and preserves the command DTO fields', () => {
    for (const kind of v1Contract.sync.commandKinds) {
      const parsed = parseSyncCommand({
        operationId: 'operation-1',
        entityId: 'entry-1',
        kind,
        ...(kind === 'createEntry' ? {} : { baseVersion: 1 }),
        payload: {},
      });
      expect(parsed.kind).toBe(kind);
      expect(new Set(Object.keys({ ...parsed, baseVersion: parsed.baseVersion }))).toEqual(
        new Set(v1Contract.sync.commandFields)
      );
    }
  });

  it('keeps the stable error envelope available to clients', () => {
    const reply = {
      code: vi.fn().mockReturnThis(),
      send: vi.fn(),
    };
    sendError(
      reply as unknown as FastifyReply,
      new ApiError(409, ErrorCodes.VERSION_CONFLICT, 'Entry changed', { actual: 4 }),
      'request-1'
    );

    expect(reply.code).toHaveBeenCalledWith(409);
    expect(reply.send).toHaveBeenCalledWith({
      error: {
        code: ErrorCodes.VERSION_CONFLICT,
        message: 'Entry changed',
        details: { actual: 4 },
        requestId: 'request-1',
        currentVersion: 4,
      },
    });
    const body = reply.send.mock.calls[0]?.[0] as { error: Record<string, unknown> };
    expect(Object.keys(body.error)).toEqual(v1Contract.errorEnvelope.fields);
  });

  it('defines a padded 32-byte SHA-256 artifact-session checksum', () => {
    const checksum = createHash('sha256').update('abc').digest('base64');

    expect(new Set(v1Contract.artifactSessions.createRequestFields)).toEqual(
      new Set([
        'operationId',
        'entryId',
        'artifactId',
        'type',
        'durationSeconds',
        'sizeBytes',
        'checksumSha256',
        'baseVersion',
      ])
    );
    expect(v1Contract.artifactSessions.checksumSha256).toEqual({
      encoding: 'padded-base64',
      decodedByteLength: 32,
    });
    expect(checksum).toMatch(/^[A-Za-z0-9+/]{43}=$/);
    expect(Buffer.from(checksum, 'base64')).toHaveLength(
      v1Contract.artifactSessions.checksumSha256.decodedByteLength
    );
  });
});
