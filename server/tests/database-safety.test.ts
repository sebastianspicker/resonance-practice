// Runs destructive-database guards in subprocesses to prove unsafe URLs fail before setup.
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { assertTestDatabaseUrl } from './support/databaseSafety.js';
import { expectUnsafeDatabaseUrlStopsScript } from './support/unsafeScriptHarness.js';

const repositoryRoot = fileURLToPath(new URL('../..', import.meta.url));

describe('destructive test database guard', () => {
  it.each([
    'postgresql://user:password@localhost:5432/resonance_test',
    'postgres://user:password@[::1]:5432/resonance_test?schema=public',
  ])('accepts the dedicated test database: %s', (url) => {
    expect(() => assertTestDatabaseUrl(url)).not.toThrow();
  });

  it.each([
    'postgresql://test-user:password@prod.example:5432/resonance',
    'postgresql://user:test-password@prod.example:5432/resonance',
    'postgresql://user:password@test-db.example:5432/resonance',
    'postgresql://user:password@prod.example:5432/resonance?schema=test',
    'postgresql://user:password@prod.example:5432/resonance_testing',
    'postgresql://user:password@localhost:5432/resonance_test?schema=private',
    'postgresql://user:password@localhost:5432/resonance_test?options=-csearch_path%3Dprivate',
    'postgresql://user:password@localhost:5432/resonance_test?search_path=private',
    'mysql://user:password@localhost:3306/resonance_test',
  ])('rejects a misleading non-test database URL: %s', (url) => {
    expect(() => assertTestDatabaseUrl(url)).toThrow('Refusing destructive test setup');
  });

  it('does not include credentials in a rejection message', () => {
    const secret = 'do-not-print-this-password';
    expect(() =>
      assertTestDatabaseUrl(`postgresql://user:${secret}@prod.example:5432/resonance`)
    ).toThrowError(expect.not.stringContaining(secret));
  });

  it('stops local CI before any npm migration command for an unsafe inherited URL', () => {
    expectUnsafeDatabaseUrlStopsScript(
      repositoryRoot,
      'scripts/ci-local.sh',
      'Refusing destructive test setup',
      'resonance-db-guard-'
    );
  });
});
