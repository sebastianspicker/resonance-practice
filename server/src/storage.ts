import { S3Client, HeadBucketCommand, CreateBucketCommand } from '@aws-sdk/client-s3';
import { config } from './config.js';

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
export async function ensureBucket(s3: S3Client) {
  try {
    await s3.send(new HeadBucketCommand({ Bucket: config.s3.bucket }));
  } catch (err: unknown) {
    if (isBucketNotFoundError(err)) {
      await s3.send(new CreateBucketCommand({ Bucket: config.s3.bucket }));
    } else {
      throw err;
    }
  }
}

/**
 * Detect "bucket does not exist" errors from HeadBucketCommand.
 * AWS S3 returns HTTP 404 (name: NotFound). Some S3-compatible stores
 * return NoSuchBucket instead.
 */
function isBucketNotFoundError(err: unknown): boolean {
  if (typeof err !== 'object' || err === null) return false;
  const s3Err = err as { name?: string; $metadata?: { httpStatusCode?: number } };
  if (s3Err.name === 'NotFound' || s3Err.name === 'NoSuchBucket') return true;
  if (s3Err.$metadata?.httpStatusCode === 404) return true;
  return false;
}
