import { describe, expect, it } from 'vitest';
import { toArtifactResponseDto } from '../src/modules/entries/application/dto.js';

describe('artifact response DTO', () => {
  it('never serializes object keys, confirmation material, or cleanup metadata', () => {
    const dto = toArtifactResponseDto({
      id: 'artifact-1',
      entryId: 'entry-1',
      type: 'audio',
      durationSeconds: 12,
      createdAt: new Date('2026-08-30T00:00:00Z'),
      uploadState: 'uploaded',
      storageKey: 'artifacts/internal/object',
      remoteUrl: 'https://storage.example.test/private',
      expectedSizeBytes: 42,
      uploadExpiresAt: new Date(),
      confirmationToken: 'secret',
      failedAt: new Date(),
    });

    expect(dto).toEqual({
      id: 'artifact-1',
      entryId: 'entry-1',
      type: 'audio',
      durationSeconds: 12,
      createdAt: new Date('2026-08-30T00:00:00Z'),
      uploadState: 'uploaded',
      expectedSizeBytes: 42,
    });
    expect(JSON.stringify(dto)).not.toMatch(/storageKey|remoteUrl|confirmationToken|failedAt/);
  });
});
