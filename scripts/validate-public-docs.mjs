#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, statSync } from 'node:fs';
import { dirname, extname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const failures = [];

function repositoryFiles(pathspec) {
  const output = execFileSync(
    'git',
    ['ls-files', '--cached', '--others', '--exclude-standard', '--', pathspec],
    { cwd: root, encoding: 'utf8' },
  );
  return [...new Set(output.trim().split('\n').filter(Boolean))].filter((file) =>
    existsSync(resolve(root, file)),
  );
}

function fail(message) {
  failures.push(message);
}

function validateMarkdown() {
  const files = repositoryFiles('*.md');
  let imageCount = 0;

  for (const file of files) {
    const absolute = resolve(root, file);
    const content = readFileSync(absolute, 'utf8');
    const inlineLink = /(!?)\[([^\]]*)\]\(([^)]+)\)/g;

    for (const match of content.matchAll(inlineLink)) {
      const [, image, label, rawTarget] = match;
      if (image) {
        imageCount += 1;
        if (!label.trim()) fail(`${file}: image alt text is empty`);
      }

      let target = rawTarget.trim();
      if (target.startsWith('<') && target.endsWith('>')) {
        target = target.slice(1, -1);
      }
      target = target.split('#', 1)[0].split('?', 1)[0];
      if (!target || /^(https?:|mailto:|tel:)/i.test(target)) continue;

      try {
        target = decodeURIComponent(target);
      } catch {
        fail(`${file}: link target is not valid URI text: ${rawTarget}`);
        continue;
      }

      const resolvedTarget = resolve(dirname(absolute), target);
      if (!existsSync(resolvedTarget)) {
        fail(`${file}: local link does not resolve: ${rawTarget}`);
      }
    }
  }

  return { markdownFiles: files.length, markdownImages: imageCount };
}

function pngMetadata(data, file) {
  const signature = '89504e470d0a1a0a';
  if (data.length < 24 || data.toString('hex', 0, 8) !== signature) {
    fail(`${file}: not a valid PNG`);
    return null;
  }
  return { width: data.readUInt32BE(16), height: data.readUInt32BE(20) };
}

function validateScreenshotManifest(manifestFile) {
  const absoluteManifest = resolve(root, manifestFile);
  const directory = dirname(absoluteManifest);
  let manifest;
  try {
    manifest = JSON.parse(readFileSync(absoluteManifest, 'utf8'));
  } catch (error) {
    fail(`${manifestFile}: invalid JSON: ${error.message}`);
    return 0;
  }

  if (!/^[0-9a-f]{40}$/.test(manifest.source?.commit ?? '')) {
    fail(`${manifestFile}: source.commit must be a full Git SHA`);
  }
  if (manifest.source?.dirty !== false) {
    fail(`${manifestFile}: source.dirty must be false`);
  }
  if (manifest.verification?.humanVisualInspection !== 'passed') {
    fail(`${manifestFile}: human visual inspection is not passed`);
  }
  if (manifest.verification?.captureLogsPublished !== false) {
    fail(`${manifestFile}: captureLogsPublished must be false`);
  }

  const captures = Array.isArray(manifest.captures) ? manifest.captures : [];
  if (captures.length === 0) fail(`${manifestFile}: captures must not be empty`);
  if (manifest.verification?.screenshotCount !== captures.length) {
    fail(`${manifestFile}: screenshotCount does not match captures length`);
  }

  const hashes = new Set();
  const declaredFiles = new Set();
  for (const capture of captures) {
    const file = capture.file;
    if (typeof file !== 'string' || file.includes('/') || extname(file).toLowerCase() !== '.png') {
      fail(`${manifestFile}: invalid capture filename: ${String(file)}`);
      continue;
    }
    if (declaredFiles.has(file)) fail(`${manifestFile}: duplicate capture filename: ${file}`);
    declaredFiles.add(file);

    const absolute = resolve(directory, file);
    if (!existsSync(absolute) || !statSync(absolute).isFile()) {
      fail(`${manifestFile}: missing capture: ${file}`);
      continue;
    }
    const data = readFileSync(absolute);
    const metadata = pngMetadata(data, file);
    const sha256 = createHash('sha256').update(data).digest('hex');
    if (capture.sha256 !== sha256) fail(`${manifestFile}: checksum mismatch: ${file}`);
    if (hashes.has(sha256)) fail(`${manifestFile}: duplicate image content: ${file}`);
    hashes.add(sha256);
    if (metadata && (capture.width !== metadata.width || capture.height !== metadata.height)) {
      fail(`${manifestFile}: dimensions mismatch: ${file}`);
    }
  }

  const publicFiles = repositoryFiles(`${manifestFile.slice(0, manifestFile.lastIndexOf('/'))}/*`);
  for (const file of publicFiles) {
    const name = file.slice(file.lastIndexOf('/') + 1);
    if (name.endsWith('.log')) fail(`${manifestFile}: published capture log: ${name}`);
    if (name.endsWith('.png') && !declaredFiles.has(name)) {
      fail(`${manifestFile}: undeclared PNG: ${name}`);
    }
  }

  return captures.length;
}

const markdown = validateMarkdown();
const manifests = repositoryFiles('docs/assets/screenshots/approved/*/manifest.json');
let screenshotCount = 0;
for (const manifest of manifests) screenshotCount += validateScreenshotManifest(manifest);

if (failures.length > 0) {
  for (const failure of failures) console.error(`- ${failure}`);
  console.error(`Public documentation validation failed with ${failures.length} issue(s).`);
  process.exit(1);
}

console.log(
  `Public documentation validation passed: ${markdown.markdownFiles} Markdown files, ` +
    `${markdown.markdownImages} image references, ${manifests.length} screenshot manifest(s), ` +
    `${screenshotCount} approved captures.`,
);
