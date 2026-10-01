import type { Prisma } from '@prisma/client';
import { lockEntry } from '../../../entries/application/locks.js';

export type ArtifactCandidate = { id: string; entryId: string };

export type LockedArtifact = NonNullable<
  Awaited<ReturnType<Prisma.TransactionClient['artifact']['findUnique']>>
>;

export async function lockAndFindArtifact(
  tx: Prisma.TransactionClient,
  candidate: ArtifactCandidate
) {
  await lockEntry(tx, candidate.entryId);
  return tx.artifact.findUnique({ where: { id: candidate.id } });
}

export function isCandidateArtifactInState(
  artifact: Pick<LockedArtifact, 'entryId' | 'uploadState'>,
  candidate: Pick<ArtifactCandidate, 'entryId'>,
  uploadState: 'failed' | 'uploading'
) {
  return artifact.entryId === candidate.entryId && artifact.uploadState === uploadState;
}
