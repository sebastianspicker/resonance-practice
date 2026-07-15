import { spawnSync } from 'node:child_process';
import { chmodSync, existsSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import { assertTestDatabaseUrl } from './databaseSafety.js';

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
    const temporaryBin = mkdtempSync(path.join(tmpdir(), 'resonance-db-guard-'));
    const sentinel = path.join(temporaryBin, 'npm-invoked');
    const mockNpm = path.join(temporaryBin, 'npm');
    writeFileSync(mockNpm, '#!/bin/sh\n: > "$NPM_SENTINEL"\nexit 99\n');
    chmodSync(mockNpm, 0o755);

    try {
      const secret = 'must-not-appear';
      const result = spawnSync('/bin/bash', ['scripts/ci-local.sh'], {
        cwd: repositoryRoot,
        encoding: 'utf8',
        env: {
          ...process.env,
          DATABASE_URL: `postgresql://operator:${secret}@prod.example:5432/resonance`,
          NPM_SENTINEL: sentinel,
          PATH: `${temporaryBin}:${process.env.PATH ?? ''}`,
        },
      });

      expect(result.status).toBe(1);
      expect(result.stderr).toContain('Refusing destructive test setup');
      expect(result.stderr).not.toContain(secret);
      expect(existsSync(sentinel)).toBe(false);
    } finally {
      rmSync(temporaryBin, { recursive: true, force: true });
    }
  });
});
