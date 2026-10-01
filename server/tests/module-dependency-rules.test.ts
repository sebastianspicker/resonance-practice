// Enforces the modular-monolith boundaries: platform independence, the feature DAG, and route ownership.
import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join, normalize, relative, sep } from 'node:path';
import { describe, expect, it } from 'vitest';

const sourceRoot = join(process.cwd(), 'src');
const modulesRoot = join(sourceRoot, 'modules');

function sourceFiles(directory: string): string[] {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = join(directory, entry.name);
    return entry.isDirectory() ? sourceFiles(path) : entry.name.endsWith('.ts') ? [path] : [];
  });
}

/** Resolve every relative static import, re-export, and dynamic import of a source file. */
function relativeImports(file: string): string[] {
  const source = readFileSync(file, 'utf8');
  const pattern = /(?:\bfrom\s+|\bimport\s*\(\s*|^\s*import\s+)['"](\.[^'"]+)['"]/gm;
  return [...source.matchAll(pattern)].map((match) =>
    normalize(join(dirname(file), match[1]!)).replace(/\.js$/, '.ts')
  );
}

const ALLOWED_DEPENDENCIES: Record<string, readonly string[]> = {
  courses: [],
  entries: ['courses'],
  identity: [],
  media: ['entries'],
  reviews: ['courses', 'entries'],
  sync: ['courses', 'entries', 'media', 'reviews'],
};

const OWNED_ROUTES: Record<string, readonly string[]> = {
  courses: ['GET /api/v1/courses'],
  entries: ['GET /api/v1/courses/:courseId/entries', 'GET /api/v1/entries/:entryId'],
  identity: [
    'GET /auth/login',
    'GET /auth/oidc/login',
    'GET /auth/oidc/callback',
    'POST /auth/session',
    'POST /auth/refresh',
    'GET /auth/me',
    'POST /auth/logout',
    'GET /dev/login',
    'GET /dev/authorize',
    'POST /dev/issue',
  ],
  media: [
    'POST /api/v1/artifact-sessions',
    'POST /api/v1/artifact-sessions/:sessionId/complete',
    'POST /api/v1/artifacts/:artifactId/download-session',
  ],
  reviews: ['GET /api/v1/courses/:courseId/review-queue', 'GET /api/v1/entries/:entryId/feedback'],
  sync: ['POST /api/v1/sync/commands'],
};

describe('modular-monolith dependency rules', () => {
  it('keeps platform independent of feature modules and app composition', () => {
    for (const file of sourceFiles(join(sourceRoot, 'platform'))) {
      for (const target of relativeImports(file)) {
        expect(relative(sourceRoot, target).split(sep)[0], file).toBe('platform');
      }
    }
  });

  it('enforces the feature dependency DAG and application-only feature boundaries', () => {
    for (const file of sourceFiles(modulesRoot)) {
      const fromFeature = relative(modulesRoot, file).split(sep)[0]!;
      expect(Object.keys(ALLOWED_DEPENDENCIES)).toContain(fromFeature);
      for (const target of relativeImports(file)) {
        const fromSource = relative(sourceRoot, target).split(sep);
        expect(fromSource[0], `${file} imports ${target}`).not.toBe('app');
        if (fromSource[0] !== 'modules') continue;
        const [, toFeature, layer] = fromSource;
        if (toFeature === fromFeature) continue;
        expect(ALLOWED_DEPENDENCIES[fromFeature], `${file} imports ${target}`).toContain(toFeature);
        expect(layer, `${file} imports ${target}`).toBe('application');
      }
    }

    const visiting = new Set<string>();
    const visited = new Set<string>();
    const visit = (feature: string) => {
      expect(visiting.has(feature), `cycle through ${feature}`).toBe(false);
      if (visited.has(feature)) return;
      visiting.add(feature);
      for (const dependency of ALLOWED_DEPENDENCIES[feature] ?? []) visit(dependency);
      visiting.delete(feature);
      visited.add(feature);
    };
    for (const feature of Object.keys(ALLOWED_DEPENDENCIES)) visit(feature);
  });

  it('registers every route in exactly its owning feature http adapter', () => {
    const routePattern =
      /\bapp\.(get|post|put|patch|delete|head|options|route)\(\s*['"]?([^'",)\s]*)/g;
    for (const feature of Object.keys(ALLOWED_DEPENDENCIES)) {
      const registered = sourceFiles(join(modulesRoot, feature)).flatMap((file) => {
        const routes = [...readFileSync(file, 'utf8').matchAll(routePattern)].map(
          ([, method, path]) => `${method!.toUpperCase()} ${path}`
        );
        if (routes.length > 0) expect(relative(modulesRoot, file).split(sep)[1], file).toBe('http');
        return routes;
      });
      expect(new Set(registered), feature).toEqual(new Set(OWNED_ROUTES[feature]));
    }
  });

  it('types the authenticated user once and never asserts it in feature adapters', () => {
    for (const file of sourceFiles(sourceRoot)) {
      const source = readFileSync(file, 'utf8');
      expect(source.includes('request.user!'), file).toBe(false);
      if (/interface FastifyRequest\b/.test(source)) {
        expect(relative(sourceRoot, file)).toBe(join('platform', 'http', 'authentication.ts'));
      }
    }
  });
});
