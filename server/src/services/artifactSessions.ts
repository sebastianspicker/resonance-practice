/** Artifact upload sessions with exclusive completion claims and durable finalization. */
import type { S3Client } from '@aws-sdk/client-s3';
import { CopyObjectCommand, HeadObjectCommand, PutObjectCommand } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import type { ArtifactType, PrismaClient } from '@prisma/client';
import { config } from '../config.js';
import { ErrorCodes } from '../errorCodes.js';
import { ApiError } from '../errors.js';
import { withDeadline } from './deadline.js';
import { isS3SourceInvalidError } from './entryCascade.js';
import {
  acquireArtifactCompletionClaim,
  artifactCompletionClaimLeaseEnd,
  artifactSessionPayloadHash,
  artifactSessionCleanupAt,
  artifactStagingKey,
  type ArtifactCompletionClaim,
  assertArtifactSessionCapacity,
  assertArtifactStudentOwner,
  assertEntryActive,
  finalizeArtifactCompletionClaim,
  type EntryTransaction,
  lockArtifactQuotaIdentity,
  lockArtifactSessionIdentity,
  lockEntry,
  lockOperationIdentity,
  queueStorageDeletion,
  releaseArtifactCompletionClaim,
} from './entryTransaction.js';

const MIN_USEFUL_PRESIGN_LIFETIME_SECONDS = 5;
const MAX_PRESIGN_ATTEMPTS = 3;

export type ArtifactSessionCreate = {
  userId: string;
  operationId: string;
  entryId: string;
  artifactId: string;
  type: ArtifactType;
  durationSeconds: number;
  sizeBytes: number;
  baseVersion: number;
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
  tx: EntryTransaction,
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
  await assertArtifactStudentOwner(tx, input.userId, entry);
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
  const cleanupAt = artifactSessionCleanupAt(current);
  await queueStorageDeletion(tx, entry.id, current.storageKey, cleanupAt);
  if (current.completionFinalKey) {
    await queueStorageDeletion(tx, entry.id, current.completionFinalKey, cleanupAt);
  }
  const storageKey = artifactStagingKey(entry.id, current.artifactId);
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
  return { session, artifact, version: entry.version, completed: false };
}

async function prepareNewArtifactSession(
  tx: EntryTransaction,
  input: ArtifactSessionCreate,
  hash: string,
  now: Date,
  expiresAt: Date
) {
  const entry = await lockEntry(tx, input.entryId);
  assertEntryActive(entry);
  await assertArtifactStudentOwner(tx, input.userId, entry);
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
 * Allocate or replay an owner-bound upload session, enforce durable quotas,
 * and return a PUT credential whose lifetime never exceeds the session.
 */
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
      artifact: prepared.artifact,
      uploadUrl: null,
      requiredHeaders: null,
      expiresInSeconds: 0,
      currentVersion: prepared.version,
      completed: true,
    };
  }
  const contentType = prepared.artifact.type === 'video' ? 'video/mp4' : 'audio/m4a';
  // Signing is serialized with completion. Otherwise a completion could commit
  // between the idempotency read above and getSignedUrl(), leaking a new PUT
  // credential for an already-final artifact.
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
      const cleanupAt = artifactSessionCleanupAt(session);
      await queueStorageDeletion(tx, session.artifact.entryId, session.storageKey, cleanupAt);
      if (session.completionFinalKey) {
        await queueStorageDeletion(
          tx,
          session.artifact.entryId,
          session.completionFinalKey,
          cleanupAt
        );
      }
      const storageKey = artifactStagingKey(session.artifact.entryId, session.artifactId);
      const expiresAt = new Date(now.getTime() + config.s3.presignTtlSeconds * 1000);
      session = await tx.artifactUploadSession.update({
        where: { id: session.id },
        data: {
          storageKey,
          expiresAt,
          credentialExpiresAt: null,
          completionClaimToken: null,
          completionFinalKey: null,
          completionClaimedAt: null,
        },
        include: { artifact: true },
      });
      const artifact = await tx.artifact.update({
        where: { id: session.artifactId },
        data: {
          storageKey,
          uploadState: 'uploading',
          uploadExpiresAt: expiresAt,
          confirmationToken: null,
          failedAt: null,
        },
      });
      session = { ...session, artifact };
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
    artifact: signed.artifact,
    uploadUrl: signed.uploadUrl,
    requiredHeaders: {
      'Content-Type': contentType,
      'Content-Length': String(signed.artifact.expectedSizeBytes),
    },
    expiresInSeconds: signed.expiresInSeconds,
    currentVersion: prepared.version,
    completed: false,
  };
}

/** Retry signing only while the session and dependency deadline still permit it. */
async function presignUpload(
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
    if (remainingBudgetMs <= 0) {
      throw storageUnavailableError();
    }
    const startedAt = new Date();
    let uploadUrl: string;
    try {
      uploadUrl = await withDeadline(
        () => getSignedUrl(s3, command, { expiresIn: expiresInSeconds }),
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
  ) {
    return null;
  }
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
  return {
    expiresInSeconds,
    expiresAt: new Date(signedAt.getTime() + expiresInSeconds * 1000),
  };
}

function formatAmzDate(value: Date) {
  return value.toISOString().replace(/[-:]|\.\d{3}/g, '');
}

/** Claim, verify, copy, then finalize exactly one immutable artifact upload. */
export async function completeArtifactSession(
  prisma: PrismaClient,
  s3: S3Client,
  userId: string,
  sessionId: string
) {
  const claim = await acquireArtifactCompletionClaim(prisma, userId, sessionId);
  if (claim.completed) return { artifact: claim.artifact, currentVersion: claim.version };
  await copyArtifactCompletionClaim(prisma, s3, sessionId, claim);
  return finalizeArtifactCompletionClaim(prisma, userId, sessionId, claim);
}

/** Copy only the object observed by HeadObject; release the lease on every failure. */
async function copyArtifactCompletionClaim(
  prisma: PrismaClient,
  s3: S3Client,
  sessionId: string,
  claim: ArtifactCompletionClaim
) {
  let head;
  try {
    head = await withDeadline(
      (abortSignal) =>
        s3.send(new HeadObjectCommand({ Bucket: config.s3.bucket, Key: claim.stagingKey }), {
          abortSignal,
        }),
      config.dependencyTimeoutMs,
      'S3 HeadObject'
    );
  } catch (error) {
    await releaseArtifactCompletionClaim(prisma, sessionId, claim);
    if (isS3SourceInvalidError(error))
      throw new ApiError(409, ErrorCodes.UPLOAD_INVALID, 'Uploaded object was not found');
    throw new ApiError(503, ErrorCodes.STORAGE_UNAVAILABLE, 'Storage is temporarily unavailable');
  }
  if (head.ContentLength !== claim.expectedSizeBytes) {
    await releaseArtifactCompletionClaim(prisma, sessionId, claim);
    throw new ApiError(
      409,
      ErrorCodes.UPLOAD_INVALID,
      'Uploaded object size does not match the artifact'
    );
  }
  if (!head.ETag?.trim()) {
    await releaseArtifactCompletionClaim(prisma, sessionId, claim);
    throw new ApiError(
      409,
      ErrorCodes.UPLOAD_INVALID,
      'Uploaded object is missing a supported integrity validator'
    );
  }
  try {
    await withDeadline(
      (abortSignal) =>
        s3.send(
          new CopyObjectCommand({
            Bucket: config.s3.bucket,
            Key: claim.storageKey,
            CopySource: `${config.s3.bucket}/${encodeURIComponent(claim.stagingKey)}`,
            CopySourceIfMatch: head.ETag,
          }),
          { abortSignal }
        ),
      config.dependencyTimeoutMs,
      'S3 CopyObject'
    );
  } catch (error) {
    await releaseArtifactCompletionClaim(prisma, sessionId, claim);
    if (isS3SourceInvalidError(error)) {
      throw new ApiError(
        409,
        ErrorCodes.UPLOAD_INVALID,
        'Uploaded object changed before it could be finalized'
      );
    }
    throw new ApiError(503, ErrorCodes.STORAGE_UNAVAILABLE, 'Storage is temporarily unavailable');
  }
}
