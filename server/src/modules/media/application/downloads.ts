/** Short-lived download credentials for uploaded artifacts visible to the caller. */
import type { S3Client } from '@aws-sdk/client-s3';
import { GetObjectCommand } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import type { PrismaClient } from '@prisma/client';
import { config } from '../../../platform/config.js';
import { withDeadline } from '../../../platform/deadline.js';
import { ErrorCodes } from '../../../platform/http/errorCodes.js';
import { ApiError } from '../../../platform/http/errors.js';
import { requireVisibleCourseEntry } from '../../entries/application/authorization.js';

const DOWNLOAD_TTL_SECONDS = 900;

export async function createDownloadSession(
  prisma: PrismaClient,
  s3: S3Client,
  userId: string,
  artifactId: string
) {
  const artifact = await prisma.artifact.findUnique({
    where: { id: artifactId },
    include: { entry: true },
  });
  if (!artifact || artifact.uploadState !== 'uploaded' || !artifact.storageKey) {
    throw new ApiError(404, ErrorCodes.ARTIFACT_NOT_FOUND, 'Artifact not found');
  }
  await requireVisibleCourseEntry(prisma, userId, artifact.entry);
  const downloadUrl = await withDeadline(
    () =>
      getSignedUrl(
        s3,
        new GetObjectCommand({ Bucket: config.s3.bucket, Key: artifact.storageKey! }),
        { expiresIn: DOWNLOAD_TTL_SECONDS }
      ),
    config.dependencyTimeoutMs,
    'S3 download presign'
  );
  return { downloadUrl, expiresInSeconds: DOWNLOAD_TTL_SECONDS };
}
