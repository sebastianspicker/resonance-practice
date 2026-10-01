/** Public media projections. Storage and cleanup metadata are never transport contracts. */
import type { Artifact } from '@prisma/client';

export type ArtifactResponseDto = Pick<
  Artifact,
  'id' | 'entryId' | 'type' | 'durationSeconds' | 'createdAt' | 'uploadState' | 'expectedSizeBytes'
>;

export function toArtifactResponseDto(artifact: Artifact): ArtifactResponseDto {
  return {
    id: artifact.id,
    entryId: artifact.entryId,
    type: artifact.type,
    durationSeconds: artifact.durationSeconds,
    createdAt: artifact.createdAt,
    uploadState: artifact.uploadState,
    expectedSizeBytes: artifact.expectedSizeBytes,
  };
}
