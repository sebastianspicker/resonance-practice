/** Artifact upload completion: claim, verify and copy the staged object, then finalize. */
import type { S3Client } from '@aws-sdk/client-s3';
import { CopyObjectCommand, HeadObjectCommand } from '@aws-sdk/client-s3';
import type { PrismaClient } from '@prisma/client';
import { config } from '../../../platform/config.js';
import { withDeadline } from '../../../platform/deadline.js';
import { ErrorCodes } from '../../../platform/http/errorCodes.js';
import { ApiError } from '../../../platform/http/errors.js';
import { toArtifactResponseDto } from '../../entries/application/dto.js';
import { isS3SourceInvalidError } from './cleanup/artifactCleanup.js';
import {
  acquireArtifactCompletionClaim,
  type ArtifactCompletionClaim,
  finalizeArtifactCompletionClaim,
  releaseArtifactCompletionClaim,
} from './completionClaims.js';
import { assertSupportedMediaContainer, expectedContentType } from './mediaValidation.js';

export async function completeArtifactSession(
  prisma: PrismaClient,
  s3: S3Client,
  userId: string,
  sessionId: string
) {
  const claim = await acquireArtifactCompletionClaim(prisma, userId, sessionId);
  if (claim.completed) {
    return { artifact: toArtifactResponseDto(claim.artifact), currentVersion: claim.version };
  }
  await copyArtifactCompletionClaim(prisma, s3, sessionId, claim);
  const completed = await finalizeArtifactCompletionClaim(prisma, userId, sessionId, claim);
  // Return only the contract fields; finalization state such as `expired` stays internal.
  return {
    artifact: toArtifactResponseDto(completed.artifact),
    currentVersion: completed.currentVersion,
  };
}
async function copyArtifactCompletionClaim(
  prisma: PrismaClient,
  s3: S3Client,
  sessionId: string,
  claim: ArtifactCompletionClaim,
  timeoutMs = config.dependencyTimeoutMs
) {
  try {
    await withDeadline(
      async (abortSignal) => {
        let head;
        try {
          head = await s3.send(
            new HeadObjectCommand({
              Bucket: config.s3.bucket,
              Key: claim.stagingKey,
              ChecksumMode: 'ENABLED',
            }),
            { abortSignal }
          );
        } catch (error) {
          if (isS3SourceInvalidError(error)) {
            throw new ApiError(409, ErrorCodes.UPLOAD_INVALID, 'Uploaded object was not found');
          }
          throw error;
        }
        assertArtifactObjectMetadata(head, claim);
        await assertSupportedMediaContainer(s3, claim.stagingKey, claim.type, head.ContentLength, {
          abortSignal,
        });
        abortSignal.throwIfAborted();
        try {
          await s3.send(
            new CopyObjectCommand({
              Bucket: config.s3.bucket,
              Key: claim.storageKey,
              CopySource: `${config.s3.bucket}/${encodeURIComponent(claim.stagingKey)}`,
              CopySourceIfMatch: head.ETag,
            }),
            { abortSignal }
          );
        } catch (error) {
          if (isS3SourceInvalidError(error)) {
            throw new ApiError(
              409,
              ErrorCodes.UPLOAD_INVALID,
              'Uploaded object changed before it could be finalized'
            );
          }
          throw error;
        }
      },
      timeoutMs,
      'S3 artifact completion'
    );
  } catch (error) {
    await releaseArtifactCompletionClaim(prisma, sessionId, claim);
    if (error instanceof ApiError) throw error;
    throw new ApiError(503, ErrorCodes.STORAGE_UNAVAILABLE, 'Storage is temporarily unavailable');
  }
}

function assertArtifactObjectMetadata(
  head: {
    ContentLength?: number | undefined;
    ContentType?: string | undefined;
    ChecksumSHA256?: string | undefined;
    ETag?: string | undefined;
  },
  claim: ArtifactCompletionClaim
) {
  if (head.ContentLength !== claim.expectedSizeBytes) {
    throw new ApiError(
      409,
      ErrorCodes.UPLOAD_INVALID,
      'Uploaded object size does not match the artifact'
    );
  }
  if (head.ContentType !== expectedContentType(claim.type)) {
    throw new ApiError(
      409,
      ErrorCodes.UPLOAD_INVALID,
      'Uploaded object content type is not supported'
    );
  }
  if (head.ChecksumSHA256 !== claim.checksumSha256) {
    throw new ApiError(409, ErrorCodes.UPLOAD_INVALID, 'Uploaded object checksum does not match');
  }
  if (!head.ETag?.trim()) {
    throw new ApiError(
      409,
      ErrorCodes.UPLOAD_INVALID,
      'Uploaded object is missing a supported integrity validator'
    );
  }
}
