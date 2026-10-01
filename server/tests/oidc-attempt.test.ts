import { describe, expect, it } from 'vitest';
import {
  consumeOidcAttempt,
  consumeProdAuthCode,
  issueOidcAttempt,
  issueProdAuthCode,
  type OidcAttempt,
} from '../src/modules/identity/application/oidc.js';
import { s256CodeChallenge } from '../src/modules/identity/application/auth.js';

type StoredAttempt = {
  tokenHash: string;
  kind: 'oidc_state' | 'prod_code';
  browserBindingHash: string;
  nonceHash: string;
  verifierHash: string;
  appCodeChallenge?: string;
  userId?: string;
  expiresAt: Date;
};

function attemptStore() {
  let stored: StoredAttempt | undefined;
  const client = {
    $transaction: async (
      callback: (tx: {
        authFlowToken: {
          deleteMany: (args: { where: { tokenHash?: string } }) => Promise<{ count: number }>;
          create: (args: { data: StoredAttempt }) => Promise<void>;
          findUnique: (args: { where: { tokenHash: string } }) => Promise<StoredAttempt | null>;
        };
      }) => Promise<unknown>
    ) =>
      callback({
        authFlowToken: {
          deleteMany: async ({ where }) => {
            const matches = !where.tokenHash || stored?.tokenHash === where.tokenHash;
            if (matches) stored = undefined;
            return { count: matches ? 1 : 0 };
          },
          create: async ({ data }) => {
            stored = data;
          },
          findUnique: async ({ where }) => (stored?.tokenHash === where.tokenHash ? stored : null),
        },
      }),
  };
  return { client, record: () => stored };
}

describe('OIDC attempt binding', () => {
  it('requires the state, nonce, PKCE verifier, and browser binding exactly once', async () => {
    const store = attemptStore();
    const attempt = await issueOidcAttempt(
      store.client as never,
      s256CodeChallenge('a'.repeat(43))
    );
    expect(store.record()).toMatchObject({
      kind: 'oidc_state',
      browserBindingHash: expect.any(String),
      nonceHash: expect.any(String),
      verifierHash: expect.any(String),
    });

    const mismatched: OidcAttempt = { ...attempt, browserBinding: `${attempt.browserBinding}x` };
    await expect(consumeOidcAttempt(store.client as never, mismatched)).resolves.toBe(false);
    await expect(consumeOidcAttempt(store.client as never, attempt)).resolves.toBe(true);
    await expect(consumeOidcAttempt(store.client as never, attempt)).resolves.toBe(false);
  });

  it('binds a production authorization code to the native PKCE verifier without consuming a mismatch', async () => {
    const store = attemptStore();
    const verifier = 'a'.repeat(43);
    const code = await issueProdAuthCode(
      store.client as never,
      'user-1',
      s256CodeChallenge(verifier)
    );

    await expect(
      consumeProdAuthCode(store.client as never, code, 'b'.repeat(43))
    ).resolves.toBeNull();
    await expect(consumeProdAuthCode(store.client as never, code, verifier)).resolves.toBe(
      'user-1'
    );
    await expect(consumeProdAuthCode(store.client as never, code, verifier)).resolves.toBeNull();
  });
});
