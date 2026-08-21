import { nanoid } from 'nanoid';
import { limits } from '../../config.js';
import { ErrorCodes } from '../../errorCodes.js';
import { ApiError } from '../../errors.js';
import {
  requireClientId,
  requireEnum,
  requireField,
  requireNumber,
  requireString,
} from '../../validation.js';

export type FeedbackMarker = { timeSeconds: number; text: string };

export type ParsedFeedbackRequest = {
  requestedFeedbackId: string | undefined;
  targetType: 'entry' | 'artifact';
  targetId: string;
  status: 'ok' | 'needs_revision' | 'next_goal';
  commentsText: string;
  markers: FeedbackMarker[];
};

export function parseFeedbackRequest(body: Record<string, unknown>): ParsedFeedbackRequest {
  const requestedFeedbackId = body.id === undefined ? undefined : requireClientId(body.id, 'id');
  const targetType = requireEnum(requireField(body.targetType, 'targetType'), 'targetType', [
    'entry',
    'artifact',
  ] as const);
  const targetId = requireString(requireField(body.targetId, 'targetId'), 'targetId');
  const status = requireEnum(requireField(body.status, 'status'), 'status', [
    'ok',
    'needs_revision',
    'next_goal',
  ] as const);
  const commentsText = requireString(
    requireField(body.commentsText, 'commentsText'),
    'commentsText',
    { minLength: 1, max: limits.maxCommentsTextLength }
  );
  const rawMarkers = Object.prototype.hasOwnProperty.call(body, 'markers')
    ? requireMarkerArray(body.markers)
    : [];
  return {
    requestedFeedbackId,
    targetType,
    targetId,
    status,
    commentsText,
    markers: parseFeedbackMarkers(rawMarkers),
  };
}

export function makeMarkerCreates(markers: FeedbackMarker[]) {
  return markers.map((marker) => ({
    id: `mk_${nanoid(10)}`,
    timeSeconds: marker.timeSeconds,
    text: marker.text,
  }));
}

export function feedbackBodyMatches(
  existingFeedback: { status: string; commentsText: string; markers: FeedbackMarker[] },
  requested: { status: string; commentsText: string; markers: FeedbackMarker[] }
): boolean {
  if (
    existingFeedback.status !== requested.status ||
    existingFeedback.commentsText !== requested.commentsText
  ) {
    return false;
  }
  return markerSetsMatch(existingFeedback.markers, requested.markers);
}

function parseFeedbackMarkers(rawMarkers: Record<string, unknown>[]): FeedbackMarker[] {
  if (rawMarkers.length > limits.maxMarkers) {
    throw new ApiError(
      400,
      ErrorCodes.VALIDATION_ERROR,
      `Too many markers (max ${limits.maxMarkers})`
    );
  }
  return rawMarkers.map((marker) => ({
    timeSeconds: requireNumber(marker.timeSeconds, 'marker.timeSeconds', {
      integer: true,
      min: 0,
      max: limits.maxMarkerTimeSeconds,
    }),
    text: requireString(requireField(marker.text, 'marker.text'), 'marker.text', {
      max: limits.maxMarkerTextLength,
    }),
  }));
}

function requireMarkerArray(value: unknown): Record<string, unknown>[] {
  if (!Array.isArray(value)) {
    throw new ApiError(400, ErrorCodes.VALIDATION_ERROR, 'Invalid array: markers');
  }
  return value as Record<string, unknown>[];
}

function markerSetsMatch(existingMarkers: FeedbackMarker[], requestedMarkers: FeedbackMarker[]) {
  if (existingMarkers.length !== requestedMarkers.length) return false;
  if (existingMarkers.length > limits.maxMarkers) return false;

  const existing = normalizeMarkers(existingMarkers);
  const requested = normalizeMarkers(requestedMarkers);
  return existing.every(
    (marker, index) =>
      marker.timeSeconds === requested[index]?.timeSeconds && marker.text === requested[index]?.text
  );
}

function normalizeMarkers(markers: FeedbackMarker[]) {
  const normalized: FeedbackMarker[] = [];
  for (let index = 0; index < limits.maxMarkers; index += 1) {
    if (index >= markers.length) break;
    const marker = markers[index]!;
    normalized.push({ timeSeconds: marker.timeSeconds, text: marker.text });
  }
  return normalized.sort((a, b) => a.timeSeconds - b.timeSeconds || a.text.localeCompare(b.text));
}
