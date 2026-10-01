/** Upload-request identity and object-key naming for artifact upload sessions. */
import { createHash } from 'node:crypto';
import type { ArtifactType } from '@prisma/client';
import { nanoid } from 'nanoid';

type ArtifactSessionIdentityInput = {
  entryId: string;
  artifactId: string;
  type: ArtifactType;
  durationSeconds: number;
  sizeBytes: number;
  checksumSha256: string;
  baseVersion: number;
};

/** Bind an operation ID to the canonical fields that define one upload request. */
export function artifactSessionPayloadHash(value: ArtifactSessionIdentityInput) {
  return createHash('sha256')
    .update(
      JSON.stringify({
        artifactId: value.artifactId,
        entryId: value.entryId,
        type: value.type,
        durationSeconds: value.durationSeconds,
        sizeBytes: value.sizeBytes,
        checksumSha256: value.checksumSha256,
        baseVersion: value.baseVersion,
      })
    )
    .digest('hex');
}

export function artifactStagingKey(entryId: string, artifactId: string) {
  return `artifacts/staging/${entryId}/${artifactId}-${nanoid(16)}`;
}

export function artifactFinalKey(entryId: string, artifactId: string, claimToken: string) {
  return `artifacts/final/${entryId}/${artifactId}-${claimToken}`;
}
