// Guards idempotent artifact-session identity before an upload credential is issued.
import { describe, expect, it } from 'vitest';
import { artifactSessionPayloadHash } from '../src/services/entryTransaction.js';

const base = {
  userId: 'student-1',
  operationId: 'upload-1',
  entryId: 'entry-1',
  artifactId: 'artifact-1',
  type: 'audio',
  durationSeconds: 30,
  sizeBytes: 1024,
  baseVersion: 4,
} as const;

describe('artifact upload identity', () => {
  it('is stable for a retry and changes when protected upload content changes', () => {
    expect(artifactSessionPayloadHash(base)).toBe(artifactSessionPayloadHash({ ...base }));
    expect(artifactSessionPayloadHash({ ...base, sizeBytes: 1025 })).not.toBe(
      artifactSessionPayloadHash(base)
    );
  });
});
