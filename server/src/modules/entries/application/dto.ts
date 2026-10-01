/** Public entry and artifact projections shared by versioned read and media adapters. */
import type { Artifact, CaptureMarker, PracticeEntry } from '@prisma/client';

type EntryWithMedia = PracticeEntry & {
  artifacts: Artifact[];
  captureMarkers: CaptureMarker[];
};

export function toEntryResponseDto(entry: EntryWithMedia) {
  return { ...toEntrySummaryDto(entry), captureMarkers: entry.captureMarkers };
}

export function toEntrySummaryDto(entry: PracticeEntry & { artifacts: Artifact[] }) {
  return {
    id: entry.id,
    courseId: entry.courseId,
    studentId: entry.studentId,
    createdAt: entry.createdAt,
    updatedAt: entry.updatedAt,
    kind: entry.kind,
    practiceDate: entry.practiceDate,
    goalText: entry.goalText,
    durationSeconds: entry.durationSeconds,
    tags: entry.tags,
    notes: entry.notes,
    status: entry.status,
    consentConfirmedAt: entry.consentConfirmedAt,
    consentScope: entry.consentScope,
    captureProfile: entry.captureProfile,
    version: entry.version,
    artifacts: entry.artifacts.map(toArtifactResponseDto),
  };
}

type ArtifactResponseDto = Pick<
  Artifact,
  'id' | 'entryId' | 'type' | 'durationSeconds' | 'createdAt' | 'uploadState' | 'expectedSizeBytes'
>;

/** The only public artifact projection; storage and cleanup metadata are never transport contracts. */
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
