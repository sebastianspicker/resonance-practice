/** Shared v1 sync-command contract parsing and response-result vocabulary. */
import { ErrorCodes } from '../../errorCodes.js';
import { ApiError } from '../../errors.js';
import { requireClientId, requireEnum, requireNumber, requireRecord } from '../../validation.js';

const COMMAND_KINDS = [
  'createEntry',
  'updateEntry',
  'replaceCaptureMarkers',
  'submitEntry',
  'deleteEntry',
  'createFeedback',
] as const;

type SyncCommandKind = (typeof COMMAND_KINDS)[number];
export type SyncCommand = {
  operationId: string;
  entityId: string;
  kind: SyncCommandKind;
  baseVersion?: number;
  payload: Record<string, unknown>;
};
export type SyncCommandStatus = 'applied' | 'duplicate' | 'conflict' | 'rejected' | 'retryable';
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
  const kind = requireEnum(body.kind, 'kind', COMMAND_KINDS);
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
