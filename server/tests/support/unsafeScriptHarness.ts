// Runs an inherited-URL safety check against a stubbed npm executable.
import { spawnSync } from 'node:child_process';
import { chmodSync, existsSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { expect } from 'vitest';

export function expectUnsafeDatabaseUrlStopsScript(
  repositoryRoot: string,
  script: string,
  expectedError: string,
  temporaryPrefix: string
) {
  const temporaryBin = mkdtempSync(path.join(tmpdir(), temporaryPrefix));
  const sentinel = path.join(temporaryBin, 'npm-invoked');
  const mockNpm = path.join(temporaryBin, 'npm');
  writeFileSync(mockNpm, '#!/bin/sh\n: > "$NPM_SENTINEL"\nexit 99\n');
  chmodSync(mockNpm, 0o755);

  try {
    const secret = 'must-not-appear';
    const result = spawnSync('/bin/bash', [script], {
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
    expect(result.stderr).toContain(expectedError);
    expect(result.stderr).not.toContain(secret);
    expect(existsSync(sentinel)).toBe(false);
  } finally {
    rmSync(temporaryBin, { recursive: true, force: true });
  }
}
