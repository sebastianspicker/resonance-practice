/** Shared v1 sync-command contract parsing and response-result vocabulary. */
import { ErrorCodes } from '../../../../platform/http/errorCodes.js';
import { ApiError } from '../../../../platform/http/errors.js';
import {
  requireClientId,
  requireEnum,
  requireNumber,
  requireRecord,
} from '../../../../platform/http/input.js';

export const SYNC_COMMAND_KINDS = [
  'createEntry',
  'updateEntry',
  'replaceCaptureMarkers',
  'submitEntry',
  'deleteEntry',
  'createFeedback',
] as const;

type SyncCommandKind = (typeof SYNC_COMMAND_KINDS)[number];
export type SyncCommand = {
  operationId: string;
  entityId: string;
  kind: SyncCommandKind;
  baseVersion?: number;
  payload: Record<string, unknown>;
};
export const SYNC_RESULT_STATUSES = [
  'applied',
  'duplicate',
  'conflict',
  'rejected',
  'retryable',
] as const;
export type SyncCommandStatus = (typeof SYNC_RESULT_STATUSES)[number];
export type SyncCommandResult = {
  operationId: string;
  entityId: string;
  kind: SyncCommandKind;
  status: SyncCommandStatus;
  code?: string;
  message?: string;
  currentVersion?: number;
  resource?: unknown;
};

export function parseSyncCommand(value: unknown): SyncCommand {
  const body = requireRecord(value, 'command');
  const kind = requireEnum(body.kind, 'kind', SYNC_COMMAND_KINDS);
  const baseVersion =
    body.baseVersion === undefined
      ? undefined
      : requireNumber(body.baseVersion, 'baseVersion', { integer: true, min: 1 });
  if (kind !== 'createEntry' && baseVersion === undefined) {
    throw new ApiError(
      400,
      ErrorCodes.VALIDATION_ERROR,
      'baseVersion is required for this command'
    );
  }
  return {
    operationId: requireClientId(body.operationId, 'operationId'),
    entityId: requireClientId(body.entityId, 'entityId'),
    kind,
    ...(baseVersion === undefined ? {} : { baseVersion }),
    payload: requireRecord(body.payload, 'payload'),
  };
}
