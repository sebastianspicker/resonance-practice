/** S3 client construction and bucket initialization with bounded remote calls. */
import {
  S3Client,
  HeadBucketCommand,
  CreateBucketCommand,
  type BucketLocationConstraint,
  type CreateBucketCommandInput,
} from '@aws-sdk/client-s3';
import { config } from './config.js';
import { withDeadline } from './services/deadline.js';

/** Keep endpoint, region, and path-style configuration at one S3 construction seam. */
export function createS3Client() {
  return new S3Client({
    region: config.s3.region,
    endpoint: config.s3.endpoint,
    credentials: {
      accessKeyId: config.s3.accessKey,
      secretAccessKey: config.s3.secretKey,
    },
    forcePathStyle: config.s3.forcePathStyle,
  });
}

/**
 * Check whether the configured bucket exists; create it only when the bucket
 * is genuinely missing (HTTP 404 / NotFound / NoSuchBucket).
 *
 * Any other HeadBucket error (e.g. 403 AccessDenied, network/TLS issues) is
 * rethrown so it surfaces immediately instead of triggering a spurious
 * CreateBucket attempt that would also fail or race with other instances.
 */
export async function checkBucketAvailable(
  s3: S3Client,
  timeoutMs = config.dependencyTimeoutMs
): Promise<void> {
  await withDeadline(
    (abortSignal) => s3.send(new HeadBucketCommand({ Bucket: config.s3.bucket }), { abortSignal }),
    timeoutMs,
    'S3 HeadBucket'
  );
}

/** Create only a confirmed-missing bucket; all remote calls honor the dependency deadline. */
export async function ensureBucket(s3: S3Client, timeoutMs = config.dependencyTimeoutMs) {
  try {
    await checkBucketAvailable(s3, timeoutMs);
  } catch (err: unknown) {
    if (isS3NotFoundError(err)) {
      try {
        await withDeadline(
          (abortSignal) =>
            s3.send(
              new CreateBucketCommand(buildCreateBucketInput(config.s3.bucket, config.s3.region)),
              { abortSignal }
            ),
          timeoutMs,
          'S3 CreateBucket'
        );
      } catch (createErr) {
        if (!isBucketAlreadyOwnedByYouError(createErr)) throw createErr;
        // Another replica may have created this account-owned bucket after our
        // 404. Re-check it rather than treating unrelated 409s as success.
        await checkBucketAvailable(s3, timeoutMs);
      }
    } else {
      throw err;
    }
  }
}

function isBucketAlreadyOwnedByYouError(err: unknown): boolean {
  return (
    typeof err === 'object' &&
    err !== null &&
    'name' in err &&
    (err as { name?: string }).name === 'BucketAlreadyOwnedByYou'
  );
}

/**
 * AWS S3 requires a LocationConstraint outside us-east-1, while us-east-1
 * rejects that field. Keep the input compatible with both AWS and local
 * S3-compatible stores.
 */
export function buildCreateBucketInput(bucket: string, region: string): CreateBucketCommandInput {
  if (region === 'us-east-1') {
    return { Bucket: bucket };
  }
  return {
    Bucket: bucket,
    CreateBucketConfiguration: {
      LocationConstraint: region as BucketLocationConstraint,
    },
  };
}

/**
 * Detect "bucket does not exist" errors from HeadBucketCommand.
 * AWS S3 returns HTTP 404 (name: NotFound). Some S3-compatible stores
 * return NoSuchBucket instead.
 */
export function isS3NotFoundError(err: unknown): boolean {
  if (typeof err !== 'object' || err === null) return false;
  const s3Err = err as { name?: string; $metadata?: { httpStatusCode?: number } };
  if (s3Err.name === 'NotFound' || s3Err.name === 'NoSuchBucket' || s3Err.name === 'NoSuchKey') {
    return true;
  }
  if (s3Err.$metadata?.httpStatusCode === 404) return true;
  return false;
}
