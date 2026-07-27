// Unit-tests S3 bucket setup, presigning, copy verification, and bounded storage failures.
import { describe, expect, it, beforeEach } from 'vitest';
import { S3Client, HeadBucketCommand, CreateBucketCommand } from '@aws-sdk/client-s3';
import { mockClient } from 'aws-sdk-client-mock';
import { buildCreateBucketInput, ensureBucket, isS3NotFoundError } from '../src/storage.js';

const s3Mock = mockClient(S3Client);

async function ensureConfiguredBucket() {
  await ensureBucket(new S3Client({}));
}

describe('ensureBucket', () => {
  beforeEach(() => {
    s3Mock.reset();
  });

  it.each([
    ['does not create bucket when HeadBucket succeeds', undefined, 0],
    [
      'creates bucket on 404 NotFound error',
      Object.assign(new Error('Not Found'), {
        name: 'NotFound',
        $metadata: { httpStatusCode: 404 },
      }),
      1,
    ],
  ])('%s', async (_name, headError, expectedCreateCalls) => {
    if (headError) {
      s3Mock.on(HeadBucketCommand).rejects(headError);
    } else {
      s3Mock.on(HeadBucketCommand).resolves({});
    }
    s3Mock.on(CreateBucketCommand).resolves({});

    await ensureConfiguredBucket();

    expect(s3Mock.commandCalls(HeadBucketCommand)).toHaveLength(1);
    expect(s3Mock.commandCalls(CreateBucketCommand)).toHaveLength(expectedCreateCalls);
  });

  it('creates bucket on NoSuchBucket error', async () => {
    const noSuchBucketError = Object.assign(new Error('No such bucket'), {
      name: 'NoSuchBucket',
      $metadata: { httpStatusCode: 404 },
    });
    s3Mock.on(HeadBucketCommand).rejects(noSuchBucketError);
    s3Mock.on(CreateBucketCommand).resolves({});

    const s3 = new S3Client({});
    await ensureBucket(s3);

    expect(s3Mock.commandCalls(CreateBucketCommand).length).toBe(1);
  });

  it('accepts a create race only when the bucket is confirmed account-owned', async () => {
    const notFound = Object.assign(new Error('Not Found'), {
      name: 'NotFound',
      $metadata: { httpStatusCode: 404 },
    });
    const createdByPeer = Object.assign(new Error('Already owned'), {
      name: 'BucketAlreadyOwnedByYou',
      $metadata: { httpStatusCode: 409 },
    });
    s3Mock.on(HeadBucketCommand).rejectsOnce(notFound).resolves({});
    s3Mock.on(CreateBucketCommand).rejects(createdByPeer);

    await expect(ensureBucket(new S3Client({}))).resolves.toBeUndefined();
    expect(s3Mock.commandCalls(HeadBucketCommand).length).toBe(2);
  });

  it('does not swallow a globally conflicting bucket name', async () => {
    s3Mock.on(HeadBucketCommand).rejects(
      Object.assign(new Error('Not Found'), {
        name: 'NotFound',
        $metadata: { httpStatusCode: 404 },
      })
    );
    s3Mock.on(CreateBucketCommand).rejects(
      Object.assign(new Error('Already exists'), {
        name: 'BucketAlreadyExists',
        $metadata: { httpStatusCode: 409 },
      })
    );

    await expect(ensureBucket(new S3Client({}))).rejects.toThrow('Already exists');
  });

  it('rethrows AccessDenied (403) instead of creating bucket (bug #38)', async () => {
    const accessDeniedError = Object.assign(new Error('Access Denied'), {
      name: 'AccessDenied',
      $metadata: { httpStatusCode: 403 },
    });
    s3Mock.on(HeadBucketCommand).rejects(accessDeniedError);
    s3Mock.on(CreateBucketCommand).resolves({});

    const s3 = new S3Client({});
    await expect(ensureBucket(s3)).rejects.toThrow('Access Denied');

    // CreateBucket should NOT have been called
    expect(s3Mock.commandCalls(CreateBucketCommand).length).toBe(0);
  });

  it('rethrows network/TLS errors instead of creating bucket', async () => {
    const networkError = new Error('connect ECONNREFUSED');
    s3Mock.on(HeadBucketCommand).rejects(networkError);
    s3Mock.on(CreateBucketCommand).resolves({});

    const s3 = new S3Client({});
    await expect(ensureBucket(s3)).rejects.toThrow('connect ECONNREFUSED');

    expect(s3Mock.commandCalls(CreateBucketCommand).length).toBe(0);
  });

  it('bounds a bucket probe even when the client never settles', async () => {
    s3Mock.on(HeadBucketCommand).callsFake(() => new Promise(() => {}));

    await expect(ensureBucket(new S3Client({}), 10)).rejects.toThrow(
      'S3 HeadBucket timed out after 10ms'
    );
    expect(s3Mock.commandCalls(CreateBucketCommand)).toHaveLength(0);
  });
});

describe('buildCreateBucketInput', () => {
  it('omits LocationConstraint for us-east-1', () => {
    expect(buildCreateBucketInput('resonance-test', 'us-east-1')).toEqual({
      Bucket: 'resonance-test',
    });
  });

  it('sets LocationConstraint for other AWS regions', () => {
    expect(buildCreateBucketInput('resonance-test', 'eu-central-1')).toEqual({
      Bucket: 'resonance-test',
      CreateBucketConfiguration: { LocationConstraint: 'eu-central-1' },
    });
  });
});

describe('isS3NotFoundError', () => {
  it('recognizes missing bucket and object responses', () => {
    expect(isS3NotFoundError({ name: 'NotFound' })).toBe(true);
    expect(isS3NotFoundError({ name: 'NoSuchBucket' })).toBe(true);
    expect(isS3NotFoundError({ name: 'NoSuchKey' })).toBe(true);
    expect(isS3NotFoundError({ $metadata: { httpStatusCode: 404 } })).toBe(true);
  });

  it('does not classify access or transport failures as missing objects', () => {
    expect(isS3NotFoundError({ name: 'AccessDenied', $metadata: { httpStatusCode: 403 } })).toBe(
      false
    );
    expect(isS3NotFoundError(new Error('connect ECONNREFUSED'))).toBe(false);
  });
});
