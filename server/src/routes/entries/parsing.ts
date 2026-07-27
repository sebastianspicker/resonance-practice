/** Entry-route payload parsing kept separate from persistence side effects. */
import type { PracticeEntry } from '@prisma/client';
import { limits } from '../../config.js';
import { ErrorCodes } from '../../errorCodes.js';
import { ApiError } from '../../errors.js';
import {
  requireBoolean,
  requireClientId,
  requireEnum,
  requireField,
  requireNumber,
  requireString,
  requireStringArray,
  requireValidDate,
} from '../../validation.js';

export const CAPTURE_MARKER_KINDS = [
  'phase_setup',
  'phase_modeling',
  'phase_guided_practice',
  'phase_student_work',
  'phase_feedback',
  'phase_reflection',
  'moment_question',
  'moment_musical_model',
  'moment_student_response',
  'moment_transition',
  'privacy_note',
] as const;

const CAPTURE_PROFILES = [
  'room_overview',
  'teacher_learner',
  'instrument_closeup',
  'ensemble_group',
  'group_work',
] as const;

const RESTRICTED_ENTRY_PATCH_FIELDS = [
  'goalText',
  'practiceDate',
  'tags',
  'durationSeconds',
  'notes',
  'kind',
  'consentConfirmed',
  'consentScope',
  'captureProfile',
];

type EntryKind = 'practice' | 'teaching_lesson';
type ConsentScope = 'private_course_review';
type CaptureProfile = (typeof CAPTURE_PROFILES)[number];

type EntryMetadata = {
  kind: EntryKind;
  consentConfirmedAt: Date | null;
  consentScope: ConsentScope | null;
  captureProfile: CaptureProfile | null;
};

type EntryPatchBase = Pick<
  PracticeEntry,
  'kind' | 'consentConfirmedAt' | 'consentScope' | 'captureProfile'
>;

function normalizeTags(rawTags: unknown) {
  const tags = requireStringArray(rawTags, 'tags', { max: limits.maxTags });
  return tags
    .slice(0, limits.maxTags)
    .map((tag) => requireString(tag, 'tags[]', { minLength: 1, max: limits.maxTagLength }));
}

function parseDuration(value: unknown, allowNull = false) {
  if (allowNull && value === null) return null;
  return requireNumber(value, 'durationSeconds', {
    integer: true,
    min: 0,
    max: limits.maxDurationSeconds,
  });
}

function validateEntryMetadata(metadata: EntryMetadata) {
  const hasConfirmedConsent = metadata.consentConfirmedAt !== null;
  const hasConsentScope = metadata.consentScope !== null;
  if (hasConfirmedConsent !== hasConsentScope) {
    const message = hasConfirmedConsent
      ? 'consentScope is required when consentConfirmed is true'
      : 'consentScope is only valid when consentConfirmed is true';
    throw new ApiError(400, ErrorCodes.VALIDATION_ERROR, message);
  }
  if (metadata.kind !== 'practice') return;
  if (hasConfirmedConsent) {
    throw new ApiError(
      400,
      ErrorCodes.VALIDATION_ERROR,
      'Consent metadata is only valid for teaching lesson entries'
    );
  }
  if (metadata.captureProfile !== null) {
    throw new ApiError(
      400,
      ErrorCodes.VALIDATION_ERROR,
      'captureProfile is only valid for teaching lesson entries'
    );
  }
}

export function parseEntryCreateBody(body: Record<string, unknown>) {
  const consentConfirmed =
    body.consentConfirmed === undefined
      ? false
      : requireBoolean(body.consentConfirmed, 'consentConfirmed');
  const metadata = {
    kind:
      body.kind === undefined
        ? 'practice'
        : requireEnum(body.kind, 'kind', ['practice', 'teaching_lesson'] as const),
    consentConfirmedAt: consentConfirmed ? new Date() : null,
    consentScope:
      body.consentScope === undefined || body.consentScope === null
        ? null
        : requireEnum(body.consentScope, 'consentScope', ['private_course_review'] as const),
    captureProfile:
      body.captureProfile === undefined || body.captureProfile === null
        ? null
        : requireEnum(body.captureProfile, 'captureProfile', CAPTURE_PROFILES),
  };
  validateEntryMetadata(metadata);
  return {
    id: requireClientId(requireField(body.id, 'id'), 'id'),
    ...metadata,
    practiceDate: requireValidDate(body.practiceDate, 'practiceDate'),
    goalText: requireString(requireField(body.goalText, 'goalText'), 'goalText', { minLength: 1 }),
    durationSeconds:
      body.durationSeconds === undefined ? null : parseDuration(body.durationSeconds),
    tags: body.tags === undefined ? [] : normalizeTags(body.tags),
    notes:
      body.notes === undefined || body.notes === null ? null : requireString(body.notes, 'notes'),
  };
}

export function isExactEntryCreateRetry(
  existing: PracticeEntry,
  entryData: ReturnType<typeof parseEntryCreateBody>,
  courseId: string,
  studentId: string
) {
  return [
    existing.deletedAt === null,
    existing.courseId === courseId,
    existing.studentId === studentId,
    existing.kind === entryData.kind,
    existing.practiceDate.getTime() === entryData.practiceDate.getTime(),
    existing.goalText === entryData.goalText,
    existing.durationSeconds === entryData.durationSeconds,
    existing.tags.length === entryData.tags.length,
    existing.tags.every((tag, index) => tag === entryData.tags.at(index)),
    existing.notes === entryData.notes,
    (existing.consentConfirmedAt !== null) === (entryData.consentConfirmedAt !== null),
    existing.consentScope === entryData.consentScope,
    existing.captureProfile === entryData.captureProfile,
  ].every(Boolean);
}

export function hasRestrictedEntryPatchField(body: Record<string, unknown>) {
  return RESTRICTED_ENTRY_PATCH_FIELDS.some((field) => field in body);
}

function applyBasicPatchFields(body: Record<string, unknown>, updateData: Record<string, unknown>) {
  if ('goalText' in body) {
    updateData.goalText = requireString(body.goalText, 'goalText', { minLength: 1 });
  }
  if ('practiceDate' in body) {
    updateData.practiceDate = requireValidDate(body.practiceDate, 'practiceDate');
  }
  if ('durationSeconds' in body) {
    updateData.durationSeconds = parseDuration(body.durationSeconds, true);
  }
  if ('tags' in body) updateData.tags = normalizeTags(body.tags);
  if ('notes' in body) {
    updateData.notes = body.notes === null ? null : requireString(body.notes, 'notes');
  }
}

function nullableConsentScope(value: unknown) {
  return value === null
    ? null
    : requireEnum(value, 'consentScope', ['private_course_review'] as const);
}

function nullableCaptureProfile(value: unknown) {
  return value === null ? null : requireEnum(value, 'captureProfile', CAPTURE_PROFILES);
}

function patchedKind(body: Record<string, unknown>, entry: EntryPatchBase) {
  return 'kind' in body
    ? requireEnum(body.kind, 'kind', ['practice', 'teaching_lesson'] as const)
    : entry.kind;
}

function patchedConsentScope(body: Record<string, unknown>, entry: EntryPatchBase) {
  return 'consentScope' in body ? nullableConsentScope(body.consentScope) : entry.consentScope;
}

function patchedCaptureProfile(body: Record<string, unknown>, entry: EntryPatchBase) {
  return 'captureProfile' in body
    ? nullableCaptureProfile(body.captureProfile)
    : entry.captureProfile;
}

function resolvePatchMetadata(body: Record<string, unknown>, entry: EntryPatchBase) {
  const metadata: EntryMetadata = {
    kind: patchedKind(body, entry),
    consentConfirmedAt: entry.consentConfirmedAt,
    consentScope: patchedConsentScope(body, entry),
    captureProfile: patchedCaptureProfile(body, entry),
  };
  if (!('consentConfirmed' in body)) return metadata;

  const consentConfirmed = requireBoolean(body.consentConfirmed, 'consentConfirmed');
  metadata.consentConfirmedAt = consentConfirmed ? (entry.consentConfirmedAt ?? new Date()) : null;
  if (!consentConfirmed) metadata.consentScope = null;
  return metadata;
}

function applyMetadataPatch(
  body: Record<string, unknown>,
  metadata: EntryMetadata,
  updateData: Record<string, unknown>
) {
  if ('kind' in body) updateData.kind = metadata.kind;
  if (
    'consentScope' in body ||
    ('consentConfirmed' in body && metadata.consentConfirmedAt === null)
  ) {
    updateData.consentScope = metadata.consentScope;
  }
  if ('consentConfirmed' in body) updateData.consentConfirmedAt = metadata.consentConfirmedAt;
  if ('captureProfile' in body) updateData.captureProfile = metadata.captureProfile;
}

export function parseEntryPatchBody(body: Record<string, unknown>, entry: EntryPatchBase) {
  const updateData: Record<string, unknown> = {};
  applyBasicPatchFields(body, updateData);
  const metadata = resolvePatchMetadata(body, entry);
  validateEntryMetadata(metadata);
  applyMetadataPatch(body, metadata, updateData);
  return updateData;
}

export function requireActiveEntry(entry: { deletedAt: Date | null }) {
  if (entry.deletedAt) throw new ApiError(410, ErrorCodes.ENTRY_DELETED, 'Entry has been deleted');
}
