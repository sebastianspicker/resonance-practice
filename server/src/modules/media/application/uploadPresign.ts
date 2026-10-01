/** Bounded upload URL signing and credential-expiry verification. */
import type { S3Client } from '@aws-sdk/client-s3';
import { PutObjectCommand } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import { config } from '../../../platform/config.js';
import { withDeadline } from '../../../platform/deadline.js';
import { ErrorCodes } from '../../../platform/http/errorCodes.js';
import { ApiError } from '../../../platform/http/errors.js';

const MAX_PRESIGN_ATTEMPTS = 3;
/**
 * Clients send every `requiredHeaders` entry, including the checksum. The SDK
 * would otherwise hoist the checksum into the query string, leaving the sent
 * header unsigned, which strict S3 implementations reject.
 */
const SIGNED_UPLOAD_HEADERS = new Set(['x-amz-checksum-sha256']);

export async function presignUpload(
  s3: S3Client,
  command: PutObjectCommand,
  sessionExpiresAt: Date,
  initialExpiresInSeconds: number
) {
  let expiresInSeconds = initialExpiresInSeconds;
  const deadlineAt = Date.now() + config.dependencyTimeoutMs;
  for (let attempt = 0; attempt < MAX_PRESIGN_ATTEMPTS; attempt += 1) {
    if (expiresInSeconds < 1) break;
    const remainingBudgetMs = deadlineAt - Date.now();
    if (remainingBudgetMs <= 0) throw storageUnavailableError();
    const startedAt = new Date();
    let uploadUrl: string;
    try {
      uploadUrl = await withDeadline(
        () =>
          getSignedUrl(s3, command, {
            expiresIn: expiresInSeconds,
            unhoistableHeaders: SIGNED_UPLOAD_HEADERS,
          }),
        remainingBudgetMs,
        'S3 upload presign'
      );
    } catch {
      throw storageUnavailableError();
    }
    const finishedAt = new Date();
    const credential = parsePresignedCredential(uploadUrl);
    if (!credential) {
      throw new ApiError(
        503,
        ErrorCodes.STORAGE_UNAVAILABLE,
        'Storage returned an unverifiable upload credential'
      );
    }
    if (credential.expiresAt <= sessionExpiresAt) {
      return {
        uploadUrl,
        expiresInSeconds: credential.expiresInSeconds,
        credentialExpiresAt: credential.expiresAt,
      };
    }
    const observedSigningMs = Math.max(finishedAt.getTime() - startedAt.getTime(), 0);
    expiresInSeconds = Math.min(
      expiresInSeconds - 1,
      Math.floor((sessionExpiresAt.getTime() - finishedAt.getTime() - observedSigningMs) / 1000)
    );
  }
  throw new ApiError(
    409,
    ErrorCodes.UPLOAD_INVALID,
    'Artifact session expired before an upload credential could be issued'
  );
}

function storageUnavailableError() {
  return new ApiError(503, ErrorCodes.STORAGE_UNAVAILABLE, 'Storage is temporarily unavailable');
}

function parsePresignedCredential(uploadUrl: string) {
  let url: URL;
  try {
    url = new URL(uploadUrl);
  } catch {
    return null;
  }
  const signedAtValue = url.searchParams.get('X-Amz-Date');
  const expiresValue = url.searchParams.get('X-Amz-Expires');
  if (!signedAtValue || !expiresValue) return null;
  const match = /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$/.exec(signedAtValue);
  const expiresInSeconds = Number(expiresValue);
  if (
    !match ||
    !Number.isInteger(expiresInSeconds) ||
    expiresInSeconds < 1 ||
    expiresInSeconds > 604_800
  )
    return null;
  const signedAt = new Date(
    Date.UTC(
      Number(match[1]),
      Number(match[2]) - 1,
      Number(match[3]),
      Number(match[4]),
      Number(match[5]),
      Number(match[6])
    )
  );
  if (!Number.isFinite(signedAt.getTime()) || formatAmzDate(signedAt) !== signedAtValue)
    return null;
  return { expiresInSeconds, expiresAt: new Date(signedAt.getTime() + expiresInSeconds * 1000) };
}

function formatAmzDate(value: Date) {
  return value.toISOString().replace(/[-:]|\.\d{3}/g, '');
}
