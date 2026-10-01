import { describe, expect, it } from 'vitest';
import { issuerScopedSsoUserId } from '../src/modules/identity/application/oidc.js';

describe('issuer-scoped SSO identities', () => {
  it('does not treat a subject as globally unique', () => {
    expect(issuerScopedSsoUserId('https://issuer-a.example.test', 'same-subject')).not.toBe(
      issuerScopedSsoUserId('https://issuer-b.example.test', 'same-subject')
    );
  });
});
