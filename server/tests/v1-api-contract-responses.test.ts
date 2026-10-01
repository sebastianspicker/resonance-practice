// Live v1 responses must expose exactly the field sets declared by the canonical contract.
import request from 'supertest';
import { describe, expect, it } from 'vitest';
import contract from '../../contracts/v1-api-contract.json';
import {
  completeSession,
  createSession,
  mockStagedObject,
  sessionPayload,
} from './support/artifactUpload.js';
import { app, installBasicSuite, login } from './support/testUtils.js';
import { createEntryWith, seedEntry } from './v1-sync/support.js';

const fields = (body: object) => new Set(Object.keys(body));

describe('v1 contract response shapes', () => {
  installBasicSuite({ resetS3: true });

  it('returns artifact create, complete, and download envelopes with contract fields', async () => {
    await seedEntry('upload-entry', 'student-1');
    const token = await login('student');
    const created = await createSession(token, sessionPayload());
    expect(created.status).toBe(200);
    expect(fields(created.body)).toEqual(new Set(contract.artifactSessions.createResponseFields));
    // Every required header must be covered by the upload signature, never left in the query.
    const uploadUrl = new URL(created.body.uploadUrl);
    const signedHeaders = uploadUrl.searchParams.get('X-Amz-SignedHeaders')!.split(';');
    for (const header of Object.keys(created.body.requiredHeaders)) {
      if (header.toLowerCase().startsWith('x-amz-')) {
        expect(signedHeaders).toContain(header.toLowerCase());
        expect(uploadUrl.searchParams.has(header.toLowerCase())).toBe(false);
      }
    }

    mockStagedObject();
    const completed = await completeSession(token, created.body.sessionId);
    expect(completed.status).toBe(200);
    expect(fields(completed.body)).toEqual(
      new Set(contract.artifactSessions.completeResponseFields)
    );

    const download = await request(app.server)
      .post('/api/v1/artifacts/upload-artifact/download-session')
      .set('authorization', `Bearer ${token}`)
      .send();
    expect(download.status).toBe(200);
    expect(fields(download.body)).toEqual(
      new Set(contract.artifactSessions.downloadResponseFields)
    );
  });

  it('rejects an artifact session missing any declared request field or with a bad checksum', async () => {
    await seedEntry('upload-entry', 'student-1');
    const token = await login('student');
    for (const field of contract.artifactSessions.createRequestFields) {
      const payload: Record<string, unknown> = sessionPayload({ operationId: `missing-${field}` });
      delete payload[field];
      const response = await createSession(token, payload);
      expect(response.status, field).toBe(400);
    }
    for (const checksumSha256 of ['AAAA', 'A'.repeat(44), `${'A'.repeat(42)}==`]) {
      const response = await createSession(token, sessionPayload({ checksumSha256 }));
      expect(response.status, checksumSha256).toBe(400);
    }
  });

  it('returns sync results using only declared result fields', async () => {
    const token = await login('student');
    const response = await request(app.server)
      .post('/api/v1/sync/commands')
      .set('authorization', `Bearer ${token}`)
      .send({ commands: [createEntryWith('contract-entry', 'contract-op')] });
    expect(response.status).toBe(200);
    for (const result of response.body.results) {
      for (const key of Object.keys(result)) {
        expect(contract.sync.resultFields).toContain(key);
      }
    }
  });
});
