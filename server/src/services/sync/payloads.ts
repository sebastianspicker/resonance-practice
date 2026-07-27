/** Typed payload parsing for v1 sync commands before transactional execution. */
import type { PracticeEntry, Prisma } from '@prisma/client';
import { limits } from '../../config.js';
import { ErrorCodes } from '../../errorCodes.js';
import { ApiError } from '../../errors.js';
import {
  requireClientId,
  requireEnum,
  requireNumber,
  requireRecord,
  requireString,
  requireStringArray,
  requireValidDate,
} from '../../validation.js';

const ENTRY_KINDS = ['practice', 'teaching_lesson'] as const;
const CONSENT_SCOPES = ['private_course_review'] as const;
const CAPTURE_PROFILES = [
  'room_overview',
  'teacher_learner',
  'instrument_closeup',
  'ensemble_group',
  'group_work',
] as const;
const CAPTURE_MARKER_KINDS = [
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

export function parseEntryCreatePayload(payload: Record<string, unknown>) {
  const kind = requireEnum(payload.kind, 'payload.kind', ENTRY_KINDS);
  const consentConfirmedAt = parseNullableDate(
    payload.consentConfirmedAt,
    'payload.consentConfirmedAt'
  );
  const consentScope = parseNullableEnum(
    payload.consentScope,
    'payload.consentScope',
    CONSENT_SCOPES
  );
  const captureProfile = parseNullableEnum(
    payload.captureProfile,
    'payload.captureProfile',
    CAPTURE_PROFILES
  );
  validateCaptureMetadata(kind, consentConfirmedAt, consentScope, captureProfile);
  return {
    courseId: requireClientId(payload.courseId, 'payload.courseId'),
    kind,
    practiceDate: requireValidDate(payload.practiceDate, 'payload.practiceDate'),
    goalText: requireString(payload.goalText, 'payload.goalText', { minLength: 1 }),
    durationSeconds: parseNullableDuration(payload.durationSeconds),
    tags: parseTags(payload.tags),
    notes: parseNullableString(payload.notes, 'payload.notes'),
    consentConfirmedAt,
    consentScope,
    captureProfile,
  };
}

export function parseEntryUpdatePayload(
  payload: Record<string, unknown>,
  entry: PracticeEntry
): Prisma.PracticeEntryUpdateInput {
  const data: Prisma.PracticeEntryUpdateInput = {};
  if ('practiceDate' in payload) {
    data.practiceDate = requireValidDate(payload.practiceDate, 'payload.practiceDate');
  }
  if ('goalText' in payload) {
    data.goalText = requireString(payload.goalText, 'payload.goalText', { minLength: 1 });
  }
  if ('durationSeconds' in payload) {
    data.durationSeconds = parseNullableDuration(payload.durationSeconds);
  }
  if ('tags' in payload) data.tags = { set: parseTags(payload.tags) };
  if ('notes' in payload) data.notes = parseNullableString(payload.notes, 'payload.notes');

  const kind =
    'kind' in payload ? requireEnum(payload.kind, 'payload.kind', ENTRY_KINDS) : entry.kind;
  const consentConfirmedAt =
    'consentConfirmedAt' in payload
      ? parseNullableDate(payload.consentConfirmedAt, 'payload.consentConfirmedAt')
      : entry.consentConfirmedAt;
  const consentScope =
    'consentScope' in payload
      ? parseNullableEnum(payload.consentScope, 'payload.consentScope', CONSENT_SCOPES)
      : entry.consentScope;
  const captureProfile =
    'captureProfile' in payload
      ? parseNullableEnum(payload.captureProfile, 'payload.captureProfile', CAPTURE_PROFILES)
      : entry.captureProfile;
  validateCaptureMetadata(kind, consentConfirmedAt, consentScope, captureProfile);
  if ('kind' in payload) data.kind = kind;
  if ('consentConfirmedAt' in payload) data.consentConfirmedAt = consentConfirmedAt;
  if ('consentScope' in payload) data.consentScope = consentScope;
  if ('captureProfile' in payload) data.captureProfile = captureProfile;
  if (Object.keys(data).length === 0) {
    throw new ApiError(400, ErrorCodes.VALIDATION_ERROR, 'Update payload is empty');
  }
  return data;
}

export function parseCaptureMarkers(value: unknown) {
  if (!Array.isArray(value) || value.length > limits.maxMarkers) {
    throw new ApiError(
      400,
      ErrorCodes.VALIDATION_ERROR,
      `payload.markers must contain at most ${limits.maxMarkers} markers`
    );
  }
  const markers = value.map((raw, index) => {
    const marker = requireRecord(raw, `payload.markers[${index}]`);
    return {
      id: requireClientId(marker.id, `payload.markers[${index}].id`),
      artifactId: requireClientId(marker.artifactId, `payload.markers[${index}].artifactId`),
      timeSeconds: requireNumber(marker.timeSeconds, `payload.markers[${index}].timeSeconds`, {
        integer: true,
        min: 0,
        max: limits.maxMarkerTimeSeconds,
      }),
      kind: requireEnum(marker.kind, `payload.markers[${index}].kind`, CAPTURE_MARKER_KINDS),
      note: parseNullableString(marker.note, `payload.markers[${index}].note`),
    };
  });
  if (new Set(markers.map((marker) => marker.id)).size !== markers.length) {
    throw new ApiError(400, ErrorCodes.VALIDATION_ERROR, 'Duplicate capture marker IDs');
  }
  return markers;
}

export function parseFeedbackPayload(payload: Record<string, unknown>) {
  const rawMarkers = payload.markers === undefined ? [] : payload.markers;
  if (!Array.isArray(rawMarkers) || rawMarkers.length > limits.maxMarkers) {
    throw new ApiError(
      400,
      ErrorCodes.VALIDATION_ERROR,
      `payload.markers must contain at most ${limits.maxMarkers} markers`
    );
  }
  return {
    targetType: requireEnum(payload.targetType, 'payload.targetType', [
      'entry',
      'artifact',
    ] as const),
    targetId: requireClientId(payload.targetId, 'payload.targetId'),
    status: requireEnum(payload.status, 'payload.status', [
      'ok',
      'needs_revision',
      'next_goal',
    ] as const),
    commentsText: requireString(payload.commentsText, 'payload.commentsText', {
      minLength: 1,
      max: limits.maxCommentsTextLength,
    }),
    markers: rawMarkers.map((raw, index) => {
      const marker = requireRecord(raw, `payload.markers[${index}]`);
      return {
        id: requireClientId(marker.id, `payload.markers[${index}].id`),
        timeSeconds: requireNumber(marker.timeSeconds, `payload.markers[${index}].timeSeconds`, {
          integer: true,
          min: 0,
          max: limits.maxMarkerTimeSeconds,
        }),
        text: requireString(marker.text, `payload.markers[${index}].text`, {
          minLength: 1,
          max: limits.maxMarkerTextLength,
        }),
      };
    }),
  };
}

/** Canonicalize object-key order so idempotency hashes are stable across clients. */
export function stableJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(',')}]`;
  if (value !== null && typeof value === 'object') {
    const record = value as Record<string, unknown>;
    return `{${Object.keys(record)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${stableJson(record[key])}`)
      .join(',')}}`;
  }
  return JSON.stringify(value) ?? 'null';
}

function parseTags(value: unknown): string[] {
  if (value === undefined) return [];
  return requireStringArray(value, 'payload.tags', { max: limits.maxTags }).map((tag) =>
    requireString(tag, 'payload.tags[]', { minLength: 1, max: limits.maxTagLength })
  );
}

function parseNullableDuration(value: unknown): number | null {
  if (value === undefined || value === null) return null;
  return requireNumber(value, 'payload.durationSeconds', {
    integer: true,
    min: 0,
    max: limits.maxDurationSeconds,
  });
}

function parseNullableString(value: unknown, name: string): string | null {
  return value === undefined || value === null ? null : requireString(value, name);
}

function parseNullableDate(value: unknown, name: string): Date | null {
  return value === undefined || value === null ? null : requireValidDate(value, name);
}

function parseNullableEnum<T extends string>(
  value: unknown,
  name: string,
  allowed: readonly T[]
): T | null {
  return value === undefined || value === null ? null : requireEnum(value, name, allowed);
}

function validateCaptureMetadata(
  kind: (typeof ENTRY_KINDS)[number],
  consentConfirmedAt: Date | null,
  consentScope: (typeof CONSENT_SCOPES)[number] | null,
  captureProfile: (typeof CAPTURE_PROFILES)[number] | null
): void {
  if (
    kind === 'practice' &&
    (consentConfirmedAt !== null || consentScope !== null || captureProfile !== null)
  ) {
    throw new ApiError(
      400,
      ErrorCodes.VALIDATION_ERROR,
      'Consent and capture metadata are only valid for teaching lesson entries'
    );
  }
  if ((consentConfirmedAt === null) !== (consentScope === null)) {
    throw new ApiError(
      400,
      ErrorCodes.VALIDATION_ERROR,
      'consentConfirmedAt and consentScope must be provided together'
    );
  }
}
