import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join, normalize, relative, sep } from 'node:path';
import { describe, expect, it } from 'vitest';

function sourceFiles(directory: string): string[] {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = join(directory, entry.name);
    return entry.isDirectory() ? sourceFiles(path) : entry.name.endsWith('.ts') ? [path] : [];
  });
}

describe('modular-monolith dependency rules', () => {
  const sourceRoot = join(process.cwd(), 'src');

  it('keeps platform independent of feature modules', () => {
    for (const file of sourceFiles(join(sourceRoot, 'platform'))) {
      expect(readFileSync(file, 'utf8')).not.toMatch(/modules\//);
      expect(readFileSync(file, 'utf8')).not.toMatch(/app\//);
    }
  });

  it('enforces the feature dependency DAG and application-only feature boundaries', () => {
    const allowedDependencies: Record<string, readonly string[]> = {
      courses: [],
      entries: ['courses'],
      identity: [],
      media: ['entries'],
      reviews: ['courses', 'entries'],
      sync: ['entries', 'media', 'reviews'],
    };
    const importPattern = /from\s+['"]([^'"]+)['"]/g;

    for (const file of sourceFiles(join(sourceRoot, 'modules'))) {
      const fromFeature = relative(join(sourceRoot, 'modules'), file).split(sep)[0];
      expect(fromFeature).toBeTruthy();
      for (const match of readFileSync(file, 'utf8').matchAll(importPattern)) {
        const specifier = match[1];
        if (!specifier?.startsWith('.')) continue;
        const target = normalize(join(dirname(file), specifier)).replace(/\.js$/, '.ts');
        const moduleRelativePath = relative(join(sourceRoot, 'modules'), target);
        if (moduleRelativePath.startsWith('..')) continue;
        const [toFeature, layer] = moduleRelativePath.split(sep);
        if (!toFeature || toFeature === fromFeature) continue;
        expect(allowedDependencies[fromFeature] ?? []).toContain(toFeature);
        expect(layer).toBe('application');
      }
    }

    const visiting = new Set<string>();
    const visited = new Set<string>();
    const visit = (feature: string) => {
      expect(visiting.has(feature)).toBe(false);
      if (visited.has(feature)) return;
      visiting.add(feature);
      for (const dependency of allowedDependencies[feature] ?? []) visit(dependency);
      visiting.delete(feature);
      visited.add(feature);
    };
    for (const feature of Object.keys(allowedDependencies)) visit(feature);
  });

  it('keeps process composition as the only layer that wires feature adapters', () => {
    const appSource = readFileSync(join(sourceRoot, 'app/serverRuntime.ts'), 'utf8');
    expect(appSource).toMatch(/modules\/identity\/http/);
    expect(appSource).toMatch(/modules\/sync\/http/);
    expect(appSource).toMatch(/platform\//);
  });

  it('registers only versioned resource routes in their owning feature adapters', () => {
    const expectedRoutes = new Map([
      ['courses', new Set(['GET /api/v1/courses'])],
      [
        'entries',
        new Set(['GET /api/v1/courses/:courseId/entries', 'GET /api/v1/entries/:entryId']),
      ],
      [
        'media',
        new Set([
          'POST /api/v1/artifact-sessions',
          'POST /api/v1/artifact-sessions/:sessionId/complete',
          'POST /api/v1/artifacts/:artifactId/download-session',
        ]),
      ],
      [
        'reviews',
        new Set([
          'GET /api/v1/courses/:courseId/review-queue',
          'GET /api/v1/entries/:entryId/feedback',
        ]),
      ],
      ['sync', new Set(['POST /api/v1/sync/commands'])],
    ]);

    for (const [feature, routes] of expectedRoutes) {
      const routeFile = join(sourceRoot, 'modules', feature, 'http/routes.ts');
      const ownedRoutes = new Set(
        [...readFileSync(routeFile, 'utf8').matchAll(/app\.(get|post)\(\s*['"]([^'"]+)/g)].map(
          ([, method, path]) => `${method!.toUpperCase()} ${path}`
        )
      );
      expect(ownedRoutes).toEqual(routes);
    }
  });
});
