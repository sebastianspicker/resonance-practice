// Keeps exported security and storage seams under direct regression coverage.
import { describe, expect, it } from 'vitest';
import { config, validateDevCallbackUrl } from '../src/config.js';
import { _resetOidcClientForTesting, getOidcClient } from '../src/oidc.js';
import { artifactCompletionClaimLeaseMs } from '../src/services/entryTransaction.js';
import { buildCreateBucketInput } from '../src/storage.js';

describe('cleanup regression unit contracts', () => {
  it('allows only explicit development callback origins', () => {
    expect(validateDevCallbackUrl('resonance://auth-callback')).toBe('resonance://auth-callback');
    expect(validateDevCallbackUrl('http://localhost:3000/callback')).toBe(
      'http://localhost:3000/callback'
    );
    expect(() => validateDevCallbackUrl('http://localhost.evil.test/callback')).toThrow(
      'DEV_LOGIN_CALLBACK_URL'
    );
  });

  it('resets the OIDC test seam without bypassing missing-configuration protection', async () => {
    await expect(getOidcClient()).rejects.toThrow('OIDC is not configured');
    _resetOidcClientForTesting();
    await expect(getOidcClient()).rejects.toThrow('OIDC is not configured');
  });

  it('keeps artifact completion claims live through storage calls and settlement', () => {
    expect(artifactCompletionClaimLeaseMs()).toBe(config.dependencyTimeoutMs * 2 + 5_000);
  });

  it('uses the AWS-compatible create-bucket shape for each region class', () => {
    expect(buildCreateBucketInput('resonance', 'us-east-1')).toEqual({ Bucket: 'resonance' });
    expect(buildCreateBucketInput('resonance', 'eu-central-1')).toEqual({
      Bucket: 'resonance',
      CreateBucketConfiguration: { LocationConstraint: 'eu-central-1' },
    });
  });
});
