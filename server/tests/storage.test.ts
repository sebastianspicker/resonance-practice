import { describe, expect, it, beforeEach } from 'vitest';
import { S3Client, HeadBucketCommand, CreateBucketCommand } from '@aws-sdk/client-s3';
import { mockClient } from 'aws-sdk-client-mock';
import { ensureBucket } from '../src/storage.js';

const s3Mock = mockClient(S3Client);

describe('ensureBucket', () => {
  beforeEach(() => {
    s3Mock.reset();
  });

  it('does not create bucket when HeadBucket succeeds', async () => {
    s3Mock.on(HeadBucketCommand).resolves({});
    s3Mock.on(CreateBucketCommand).resolves({});

    const s3 = new S3Client({});
    await ensureBucket(s3);

    expect(s3Mock.commandCalls(HeadBucketCommand).length).toBe(1);
    expect(s3Mock.commandCalls(CreateBucketCommand).length).toBe(0);
  });

  it('creates bucket on 404 NotFound error', async () => {
    const notFoundError = Object.assign(new Error('Not Found'), {
      name: 'NotFound',
      $metadata: { httpStatusCode: 404 },
    });
    s3Mock.on(HeadBucketCommand).rejects(notFoundError);
    s3Mock.on(CreateBucketCommand).resolves({});

    const s3 = new S3Client({});
    await ensureBucket(s3);

    expect(s3Mock.commandCalls(HeadBucketCommand).length).toBe(1);
    expect(s3Mock.commandCalls(CreateBucketCommand).length).toBe(1);
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
});
