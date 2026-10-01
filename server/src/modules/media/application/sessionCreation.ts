/** Idempotent artifact upload-session creation, staging rotation, and upload presigning. */
import type { S3Client } from '@aws-sdk/client-s3';
import { PutObjectCommand } from '@aws-sdk/client-s3';
import type { ArtifactType, Prisma, PrismaClient } from '@prisma/client';
import { config } from '../../../platform/config.js';
import { lockOperationIdentity } from '../../../platform/database/advisoryLocks.js';
import { ErrorCodes } from '../../../platform/http/errorCodes.js';
import { ApiError } from '../../../platform/http/errors.js';
import { requireStudentOwner } from '../../entries/application/authorization.js';
import { toArtifactResponseDto } from '../../entries/application/dto.js';
import { assertEntryActive, lockEntry } from '../../entries/application/locks.js';
import { artifactSessionPayloadHash, artifactStagingKey } from './artifactIdentity.js';
import { lockArtifactSessionIdentity } from './completionClaims.js';
import { artifactCompletionClaimLeaseEnd } from './completionLease.js';
import { artifactSessionCleanupAt, queueStorageDeletion } from './storageDeletion/schedule.js';
import { assertArtifactSessionCapacity, lockArtifactQuotaIdentity } from './uploadQuota.js';
import { presignUpload } from './uploadPresign.js';

const MIN_USEFUL_PRESIGN_LIFETIME_SECONDS = 5;

export type ArtifactSessionCreate = {
  userId: string;
  operationId: string;
  entryId: string;
  artifactId: string;
  type: ArtifactType;
  durationSeconds: number;
  sizeBytes: number;
  checksumSha256: string;
  baseVersion: number;
};

type RotatableArtifactSession = {
  id: string;
  artifactId: string;
  storageKey: string;
  expiresAt: Date;
  credentialExpiresAt: Date | null;
  completionFinalKey: string | null;
  completionClaimedAt: Date | null;
};

async function prepareArtifactSession(
  prisma: PrismaClient,
  input: ArtifactSessionCreate,
  hash: string,
  now: Date,
  expiresAt: Date
) {
  return prisma.$transaction(async (tx) => {
    await lockOperationIdentity(tx, input.userId, input.operationId);
    const existing = await tx.artifactUploadSession.findUnique({
      where: { userId_operationId: { userId: input.userId, operationId: input.operationId } },
    });
    return existing
      ? prepareExistingArtifactSession(tx, input, hash, now, expiresAt, existing)
      : prepareNewArtifactSession(tx, input, hash, now, expiresAt);
  });
}
async function prepareExistingArtifactSession(
  tx: Prisma.TransactionClient,
  input: ArtifactSessionCreate,
  hash: string,
  now: Date,
  expiresAt: Date,
  existing: { id: string; payloadHash: string }
) {
  if (existing.payloadHash !== hash) {
    throw new ApiError(
      409,
      ErrorCodes.OPERATION_REUSED,
      'operationId was already used with different content'
    );
  }
  await lockArtifactSessionIdentity(tx, existing.id);
  const current = await tx.artifactUploadSession.findUniqueOrThrow({
    where: { id: existing.id },
    include: { artifact: true },
  });
  const entry = await lockEntry(tx, current.artifact.entryId);
  assertEntryActive(entry);
  await requireStudentOwner(tx, input.userId, entry, 'upload artifacts');
  if (current.completedAt) {
    return {
      session: current,
      artifact: current.artifact,
      version: entry.version,
      completed: true,
    };
  }
  if (current.expiresAt > now) {
    return {
      session: current,
      artifact: current.artifact,
      version: entry.version,
      completed: false,
    };
  }
  const { session, artifact } = await rotateStagingSession(tx, entry.id, current, expiresAt);
  return { session, artifact, version: entry.version, completed: false };
}
async function prepareNewArtifactSession(
  tx: Prisma.TransactionClient,
  input: ArtifactSessionCreate,
  hash: string,
  now: Date,
  expiresAt: Date
) {
  const entry = await lockEntry(tx, input.entryId);
  assertEntryActive(entry);
  await requireStudentOwner(tx, input.userId, entry, 'upload artifacts');
  if (entry.version !== input.baseVersion) {
    throw new ApiError(409, ErrorCodes.VERSION_CONFLICT, 'Entry has changed on the server', {
      actual: entry.version,
    });
  }
  if (entry.status !== 'draft') {
    throw new ApiError(
      409,
      ErrorCodes.ENTRY_LOCKED,
      'Artifacts can only be uploaded while the entry is a draft'
    );
  }
  await lockArtifactQuotaIdentity(tx, input.userId);
  const prior = await tx.artifact.findUnique({ where: { id: input.artifactId } });
  if (prior) throw new ApiError(409, ErrorCodes.ID_CONFLICT, 'Artifact ID is already in use');
  await assertArtifactSessionCapacity(tx, input.userId, entry.id, input.sizeBytes, now);
  const storageKey = artifactStagingKey(entry.id, input.artifactId);
  const artifact = await tx.artifact.create({
    data: {
      id: input.artifactId,
      entryId: entry.id,
      type: input.type,
      durationSeconds: input.durationSeconds,
      expectedSizeBytes: input.sizeBytes,
      storageKey,
      uploadState: 'uploading',
      uploadExpiresAt: expiresAt,
    },
  });
  const session = await tx.artifactUploadSession.create({
    data: {
      userId: input.userId,
      operationId: input.operationId,
      payloadHash: hash,
      checksumSha256: input.checksumSha256,
      artifactId: artifact.id,
      storageKey,
      expiresAt,
    },
  });
  const updated = await tx.practiceEntry.update({
    where: { id: entry.id },
    data: { version: { increment: 1 } },
  });
  return { session, artifact, version: updated.version, completed: false };
}

/**
 * Retire a session's staging (and any claimed final) key for durable cleanup
 * and point the session and its artifact at a fresh staging key.
 */
async function rotateStagingSession(
  tx: Prisma.TransactionClient,
  entryId: string,
  current: RotatableArtifactSession,
  expiresAt: Date
) {
  const cleanupAt = artifactSessionCleanupAt(current);
  await queueStorageDeletion(tx, entryId, current.storageKey, cleanupAt);
  if (current.completionFinalKey) {
    await queueStorageDeletion(tx, entryId, current.completionFinalKey, cleanupAt);
  }
  const storageKey = artifactStagingKey(entryId, current.artifactId);
  const session = await tx.artifactUploadSession.update({
    where: { id: current.id },
    data: {
      storageKey,
      expiresAt,
      credentialExpiresAt: null,
      completionClaimToken: null,
      completionFinalKey: null,
      completionClaimedAt: null,
    },
  });
  const artifact = await tx.artifact.update({
    where: { id: current.artifactId },
    data: {
      storageKey,
      uploadState: 'uploading',
      uploadExpiresAt: expiresAt,
      confirmationToken: null,
      failedAt: null,
    },
  });
  return { session, artifact };
}
export async function createArtifactSession(
  prisma: PrismaClient,
  s3: S3Client,
  input: ArtifactSessionCreate
) {
  const hash = artifactSessionPayloadHash(input);
  const now = new Date();
  const expiresAt = new Date(now.getTime() + config.s3.presignTtlSeconds * 1000);
  const prepared = await prepareArtifactSession(prisma, input, hash, now, expiresAt);
  if (prepared.completed) {
    return {
      sessionId: prepared.session.id,
      artifact: toArtifactResponseDto(prepared.artifact),
      uploadUrl: null,
      requiredHeaders: null,
      expiresInSeconds: 0,
      currentVersion: prepared.version,
      completed: true,
    };
  }
  const contentType = prepared.artifact.type === 'video' ? 'video/mp4' : 'audio/m4a';
  const signed = await prisma.$transaction(async (tx) => {
    await lockArtifactSessionIdentity(tx, prepared.session.id);
    let session = await tx.artifactUploadSession.findUniqueOrThrow({
      where: { id: prepared.session.id },
      include: { artifact: true },
    });
    if (session.completedAt) {
      throw new ApiError(409, ErrorCodes.UPLOAD_INVALID, 'Artifact session is not uploadable');
    }
    const now = new Date();
    if (
      session.completionClaimToken &&
      artifactCompletionClaimLeaseEnd(session.completionClaimedAt) > now
    ) {
      throw new ApiError(
        409,
        ErrorCodes.UPLOAD_INVALID,
        'Artifact completion is in progress; retry later'
      );
    }
    let expiresInSeconds = Math.floor((session.expiresAt.getTime() - now.getTime()) / 1000);
    if (expiresInSeconds < MIN_USEFUL_PRESIGN_LIFETIME_SECONDS) {
      const expiresAt = new Date(now.getTime() + config.s3.presignTtlSeconds * 1000);
      const rotated = await rotateStagingSession(tx, session.artifact.entryId, session, expiresAt);
      session = { ...rotated.session, artifact: rotated.artifact };
      expiresInSeconds = config.s3.presignTtlSeconds;
    }
    if (expiresInSeconds < 1) {
      throw new ApiError(409, ErrorCodes.UPLOAD_INVALID, 'Artifact session is not uploadable');
    }
    const presigned = await presignUpload(
      s3,
      new PutObjectCommand({
        Bucket: config.s3.bucket,
        Key: session.storageKey,
        ContentType: contentType,
        ContentLength: session.artifact.expectedSizeBytes ?? undefined,
        ChecksumSHA256: session.checksumSha256,
      }),
      session.expiresAt,
      expiresInSeconds
    );
    await tx.artifactUploadSession.update({
      where: { id: session.id },
      data: {
        credentialExpiresAt:
          session.credentialExpiresAt && session.credentialExpiresAt > presigned.credentialExpiresAt
            ? session.credentialExpiresAt
            : presigned.credentialExpiresAt,
      },
    });
    return {
      uploadUrl: presigned.uploadUrl,
      expiresInSeconds: presigned.expiresInSeconds,
      session,
      artifact: session.artifact,
    };
  });
  return {
    sessionId: signed.session.id,
    artifact: toArtifactResponseDto(signed.artifact),
    uploadUrl: signed.uploadUrl,
    requiredHeaders: {
      'Content-Type': contentType,
      'Content-Length': String(signed.artifact.expectedSizeBytes),
      'x-amz-checksum-sha256': signed.session.checksumSha256,
    },
    expiresInSeconds: signed.expiresInSeconds,
    currentVersion: prepared.version,
    completed: false,
  };
}
