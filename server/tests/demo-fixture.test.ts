// Validates the deterministic public demo fixture through the same standalone script used by CI.
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import {
  assertDemoDatabaseUrl,
  loadDemoFixture,
  resolveDemoFeedbackEntryId,
} from '../prisma/demoFixture.js';
import { expectUnsafeDatabaseUrlStopsScript } from './support/unsafeScriptHarness.js';

const repositoryRoot = fileURLToPath(new URL('../..', import.meta.url));

describe('demo fixture safety and feedback mapping', () => {
  it('accepts the local demo database URL', () => {
    expect(() =>
      assertDemoDatabaseUrl('postgresql://user:pass@localhost:5432/resonance')
    ).not.toThrow();
  });

  it.each([
    'postgresql://user:pass@[::1]:5432/resonance',
    'postgres://user:pass@127.0.0.1:5432/resonance?schema=public',
  ])('accepts loopback PostgreSQL URLs, including IPv6 (%s)', (databaseUrl) => {
    expect(() => assertDemoDatabaseUrl(databaseUrl)).not.toThrow();
  });

  it('rejects remote demo database URLs', () => {
    expect(() =>
      assertDemoDatabaseUrl('postgresql://user:pass@db.example.test:5432/resonance')
    ).toThrow('host must be loopback');
  });

  it('rejects unexpected local database names', () => {
    expect(() =>
      assertDemoDatabaseUrl('postgresql://user:pass@localhost:5432/resonance_test')
    ).toThrow('database name must be "resonance"');
  });

  it.each(['mysql://user:pass@localhost:3306/resonance', 'https://localhost/resonance'])(
    'rejects non-PostgreSQL demo database URLs (%s)',
    (databaseUrl) => {
      expect(() => assertDemoDatabaseUrl(databaseUrl)).toThrow(
        'protocol must be postgresql: or postgres:'
      );
    }
  );

  it.each([
    'postgresql://user:pass@localhost:5432/resonance?schema=private',
    'postgresql://user:pass@localhost:5432/resonance?schema=public&schema=private',
    'postgresql://user:pass@localhost:5432/resonance?schema=',
  ])('rejects non-public demo schemas (%s)', (databaseUrl) => {
    expect(() => assertDemoDatabaseUrl(databaseUrl)).toThrow('schema must be "public"');
  });

  it.each([
    'postgresql://user:pass@localhost:5432/resonance?options=-csearch_path%3Dprivate',
    'postgresql://user:pass@localhost:5432/resonance?search_path=private',
  ])('rejects alternate search-path overrides (%s)', (databaseUrl) => {
    expect(() => assertDemoDatabaseUrl(databaseUrl)).toThrow('must not override search_path');
  });

  it('stops demo bootstrap before npm or migrations for an unsafe inherited URL', () => {
    expectUnsafeDatabaseUrlStopsScript(
      repositoryRoot,
      'scripts/demo/bootstrap-local-demo.sh',
      'Refusing demo database mutation',
      'resonance-demo-db-guard-'
    );
  });

  it('keeps feedback parents reviewed while retaining multiple submitted entries', async () => {
    const fixture = await loadDemoFixture();
    const resolvedEntryIds = fixture.feedback.map((feedback) =>
      resolveDemoFeedbackEntryId(fixture, feedback)
    );

    expect(resolvedEntryIds).toEqual(['demo_entry_lea_reviewed_1', 'demo_entry_lea_reviewed_1']);
    expect(
      resolvedEntryIds.every(
        (entryId) => fixture.entries.find((entry) => entry.id === entryId)?.status === 'reviewed'
      )
    ).toBe(true);
    expect(fixture.entries.filter((entry) => entry.status === 'submitted')).toHaveLength(2);
  });

  it('keeps inactive demo uploads outside the startup expiry path', async () => {
    const fixture = await loadDemoFixture();
    const inactiveArtifacts = fixture.artifacts.filter(
      (artifact) => artifact.uploadState === 'pending' || artifact.uploadState === 'failed'
    );

    expect(inactiveArtifacts).not.toHaveLength(0);
    expect(
      inactiveArtifacts.every(
        (artifact) =>
          artifact.expectedSizeBytes !== null &&
          artifact.storageKey === null &&
          artifact.remoteUrl === null &&
          artifact.uploadExpiresAt === null &&
          artifact.confirmationToken === null
      )
    ).toBe(true);
  });
});
