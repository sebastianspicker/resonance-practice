/** Typed feedback-command payload parsing before transactional execution. */
import { limits } from '../../../platform/config.js';
import { ErrorCodes } from '../../../platform/http/errorCodes.js';
import { ApiError } from '../../../platform/http/errors.js';
import {
  requireClientId,
  requireEnum,
  requireNumber,
  requireRecord,
  requireString,
} from '../../../platform/http/input.js';

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
