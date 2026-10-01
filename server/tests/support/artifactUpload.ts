// Shared HTTP helpers and S3 mocks for artifact upload-session tests.
import { CopyObjectCommand, GetObjectCommand, HeadObjectCommand } from '@aws-sdk/client-s3';
import request from 'supertest';
import { app, s3Mock } from './testUtils.js';

export const uploadChecksum = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';

/** Minimal valid audio M4A: ftyp, moov with a sound track, and a non-empty mdat. */
const validM4aMedia = Buffer.concat([
  Buffer.from(
    '00000014667479704d344120000000004d3441200000002c6d6f6f76000000247472616b0000001c6d6469610000001468646c720000000000000000736f756e000000406d646174',
    'hex'
  ),
  Buffer.alloc(56, 1),
]);

export const sessionPayload = (overrides: Record<string, unknown> = {}) => ({
  operationId: 'upload-operation',
  entryId: 'upload-entry',
  artifactId: 'upload-artifact',
  type: 'audio',
  durationSeconds: 30,
  sizeBytes: 128,
  checksumSha256: uploadChecksum,
  baseVersion: 1,
  ...overrides,
});

export const createSession = (token: string, payload: Record<string, unknown>) =>
  request(app.server)
    .post('/api/v1/artifact-sessions')
    .set('authorization', `Bearer ${token}`)
    .send(payload);

export const completeSession = (token: string, sessionId: string) =>
  request(app.server)
    .post(`/api/v1/artifact-sessions/${sessionId}/complete`)
    .set('authorization', `Bearer ${token}`)
    .send();

/** Mock the staged object: HeadObject metadata, ranged media bytes, and a successful copy. */
export function mockStagedObject(
  head: Record<string, unknown> = {},
  media: Buffer = validM4aMedia
) {
  s3Mock.on(HeadObjectCommand).resolves({
    ContentLength: 128,
    ContentType: 'audio/m4a',
    ChecksumSHA256: uploadChecksum,
    ETag: '"etag"',
    ...head,
  });
  s3Mock.on(GetObjectCommand).callsFake((input) => {
    const match = /^bytes=(\d+)-(\d+)$/.exec(input.Range!)!;
    return { Body: media.subarray(Number(match[1]), Number(match[2]) + 1) };
  });
  s3Mock.on(CopyObjectCommand).resolves({});
}
