// S3 startup must only create a confirmed-missing bucket and preserve real failures.
import { CreateBucketCommand, HeadBucketCommand, S3Client } from '@aws-sdk/client-s3';
import { mockClient } from 'aws-sdk-client-mock';
import { beforeEach, describe, expect, it } from 'vitest';
import { ensureBucket, isS3NotFoundError } from '../src/storage.js';

const s3Mock = mockClient(S3Client);
const s3Error = (name: string, statusCode: number) =>
  Object.assign(new Error(name), { name, $metadata: { httpStatusCode: statusCode } });

describe('S3 bucket boundary', () => {
  beforeEach(() => s3Mock.reset());

  it('creates only after a confirmed missing response and rechecks an owned-bucket race', async () => {
    s3Mock.on(HeadBucketCommand).rejectsOnce(s3Error('NotFound', 404)).resolves({});
    s3Mock.on(CreateBucketCommand).rejects(s3Error('BucketAlreadyOwnedByYou', 409));

    await expect(ensureBucket(new S3Client({}))).resolves.toBeUndefined();
    expect(s3Mock.commandCalls(HeadBucketCommand)).toHaveLength(2);
    expect(s3Mock.commandCalls(CreateBucketCommand)).toHaveLength(1);
  });

  it('does not turn denied or transport failures into bucket creation', async () => {
    s3Mock.on(HeadBucketCommand).rejects(s3Error('AccessDenied', 403));
    await expect(ensureBucket(new S3Client({}))).rejects.toThrow('AccessDenied');
    expect(s3Mock.commandCalls(CreateBucketCommand)).toHaveLength(0);
  });

  it('recognizes only documented missing-object variants', () => {
    expect(isS3NotFoundError({ name: 'NoSuchKey' })).toBe(true);
    expect(isS3NotFoundError({ $metadata: { httpStatusCode: 404 } })).toBe(true);
    expect(isS3NotFoundError({ name: 'AccessDenied', $metadata: { httpStatusCode: 403 } })).toBe(
      false
    );
  });
});
