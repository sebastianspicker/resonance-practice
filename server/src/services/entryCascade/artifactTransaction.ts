import type { EntryTransaction } from '../entryTransaction.js';
import { lockEntry } from '../entryTransaction.js';

export type ArtifactCandidate = { id: string; entryId: string };

export type LockedArtifact = NonNullable<
  Awaited<ReturnType<EntryTransaction['artifact']['findUnique']>>
>;

export async function lockAndFindArtifact(tx: EntryTransaction, candidate: ArtifactCandidate) {
  await lockEntry(tx, candidate.entryId);
  return tx.artifact.findUnique({ where: { id: candidate.id } });
}

export async function incrementEntryVersion(tx: EntryTransaction, entryId: string) {
  await tx.practiceEntry.update({
    where: { id: entryId },
    data: { version: { increment: 1 } },
  });
}

export function isCandidateArtifactInState(
  artifact: Pick<LockedArtifact, 'entryId' | 'uploadState'>,
  candidate: Pick<ArtifactCandidate, 'entryId'>,
  uploadState: 'failed' | 'uploading'
) {
  return artifact.entryId === candidate.entryId && artifact.uploadState === uploadState;
}
