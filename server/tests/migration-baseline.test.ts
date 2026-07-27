// Enforces the single squashed alpha migration and guards against accidental history drift.
import { readdir, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

const migrationsDirectory = new URL('../prisma/migrations/', import.meta.url);

describe('alpha migration baseline', () => {
  it('contains one reset-only schema baseline', async () => {
    const entries = (await readdir(migrationsDirectory, { withFileTypes: true }))
      .filter((entry) => entry.isDirectory())
      .map((entry) => entry.name);

    expect(entries).toEqual(['20260716000000_alpha_baseline']);

    const sql = await readFile(
      join(migrationsDirectory.pathname, entries[0]!, 'migration.sql'),
      'utf8'
    );
    expect(sql).toContain('CREATE TABLE "SyncReceipt"');
    expect(sql).toContain('CREATE TABLE "ArtifactUploadSession"');
    expect(sql).toContain('"version" INTEGER NOT NULL DEFAULT 1');
    expect(sql).toContain('CREATE UNIQUE INDEX "SyncReceipt_userId_operationId_key"');
  });
});
