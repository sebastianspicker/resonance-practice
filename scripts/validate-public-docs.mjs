#!/usr/bin/env node

// Validate public documentation links and screenshot evidence lifecycle metadata.

import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import {
  existsSync,
  readFileSync,
  readdirSync,
  realpathSync,
  statSync,
} from "node:fs";
import { dirname, extname, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const failures = [];
const cliArgs = process.argv.slice(2);
const releaseMode = cliArgs.includes("--release");
const unknownArgs = cliArgs.filter((argument) => argument !== "--release");
const approvedScreenshotChange =
  /^docs\/assets\/screenshots\/approved\/[^/]+\/(?:manifest\.json|[^/]+\.png)$/;
const approvedScreenshotDocumentation = new Set([
  "docs/SCREENSHOTS.md",
  "docs/ALPHA_WALKTHROUGH.md",
  "docs/RELEASING.md",
]);

function repositoryFiles(pathspec) {
  const output = execFileSync(
    "git",
    ["ls-files", "--cached", "--others", "--exclude-standard", "--", pathspec],
    { cwd: root, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
  );
  return [...new Set(output.trim().split("\n").filter(Boolean))].filter(
    (file) => existsSync(resolve(root, file)),
  );
}

function fail(message) {
  failures.push(message);
}

function gitOutput(args) {
  return execFileSync("git", args, {
    cwd: root,
    encoding: "utf8",
  }).trim();
}

function commitResolves(commit) {
  try {
    execFileSync("git", ["cat-file", "-e", `${commit}^{commit}`], {
      cwd: root,
      stdio: "ignore",
    });
    return true;
  } catch {
    return false;
  }
}

function commitIsAncestorOfHead(commit) {
  try {
    execFileSync("git", ["merge-base", "--is-ancestor", commit, "HEAD"], {
      cwd: root,
      stdio: "ignore",
    });
    return true;
  } catch {
    return false;
  }
}

function validatePublicationChanges(sourceCommit, manifestFile, release) {
  const changedFiles = gitOutput([
    "diff",
    "--name-only",
    `${sourceCommit}..HEAD`,
  ])
    .split("\n")
    .filter(Boolean);
  for (const file of changedFiles) {
    if (
      !approvedScreenshotChange.test(file) &&
      !approvedScreenshotDocumentation.has(file) &&
      file !== `docs/release-notes/${release}.md`
    ) {
      fail(
        `${manifestFile}: publication includes a disallowed change after source.commit: ${file}`,
      );
    }
  }
}

function recordMarkdownLink(
  file,
  absolute,
  publicationCandidates,
  imageReferences,
  match,
) {
  const [, image, label, rawTarget] = match;
  if (image && !label.trim()) fail(`${file}: image alt text is empty`);

  let target = rawTarget.trim();
  if (target.startsWith("<") && target.endsWith(">")) {
    target = target.slice(1, -1);
  }
  target = target.split("#", 1)[0].split("?", 1)[0];
  if (!target || /^(https?:|mailto:|tel:)/i.test(target)) return;

  try {
    target = decodeURIComponent(target);
  } catch {
    fail(`${file}: link target is not valid URI text: ${rawTarget}`);
    return;
  }

  const resolvedTarget = resolve(dirname(absolute), target);
  if (resolvedTarget !== root && !resolvedTarget.startsWith(`${root}/`)) {
    fail(`${file}: local link escapes the repository: ${rawTarget}`);
    return;
  }
  if (!existsSync(resolvedTarget)) {
    fail(`${file}: local link does not resolve: ${rawTarget}`);
    return;
  }
  const realTarget = realpathSync(resolvedTarget);
  if (realTarget !== root && !realTarget.startsWith(`${root}/`)) {
    fail(`${file}: local link escapes the repository: ${rawTarget}`);
    return;
  }
  const repositoryPath = relative(root, resolvedTarget);
  const realRepositoryPath = relative(root, realTarget);
  if (!publicationCandidates.has(realRepositoryPath)) {
    fail(
      `${file}: local link does not resolve to a publication candidate: ${rawTarget}`,
    );
    return;
  }
  if (image && label.trim()) {
    const references = imageReferences.get(repositoryPath) ?? [];
    references.push(file);
    imageReferences.set(repositoryPath, references);
  }
}

function validateMarkdown() {
  const files = repositoryFiles("*.md");
  const publicationCandidates = new Set(repositoryFiles("."));
  const imageReferences = new Map();
  let imageCount = 0;

  for (const file of files) {
    const absolute = resolve(root, file);
    const content = readFileSync(absolute, "utf8");
    const inlineLink = /(!?)\[([^\]]*)\]\(([^)]+)\)/g;

    for (const match of content.matchAll(inlineLink)) {
      if (match[1]) imageCount += 1;
      recordMarkdownLink(
        file,
        absolute,
        publicationCandidates,
        imageReferences,
        match,
      );
    }
  }

  return {
    markdownFiles: files.length,
    markdownImages: imageCount,
    imageReferences,
  };
}

function pngMetadata(data, file) {
  const signature = "89504e470d0a1a0a";
  if (data.length < 24 || data.toString("hex", 0, 8) !== signature) {
    fail(`${file}: not a valid PNG`);
    return null;
  }
  return { width: data.readUInt32BE(16), height: data.readUInt32BE(20) };
}

function readScreenshotManifest(absoluteManifest, manifestFile) {
  try {
    return JSON.parse(readFileSync(absoluteManifest, "utf8"));
  } catch (error) {
    fail(`${manifestFile}: invalid JSON: ${error.message}`);
    return null;
  }
}

function validateSourceProvenance(
  manifest,
  manifestFile,
  { sourceLabel, releaseReady },
) {
  if (!/^[0-9a-f]{40}$/.test(manifest.source?.commit ?? "")) {
    fail(
      `${manifestFile}: ${sourceLabel} source.commit must be a full Git SHA`,
    );
  }
  if (manifest.source?.dirty !== false) {
    fail(`${manifestFile}: ${sourceLabel} source.dirty must be false`);
  }
  if (manifest.verification?.releaseReady !== releaseReady) {
    fail(
      `${manifestFile}: ${sourceLabel} manifest must set releaseReady ${releaseReady}`,
    );
  }
}

function validateManifestSource(manifest, manifestFile) {
  const sourceStatus = manifest.source?.status;
  const sourceCommit = manifest.source?.commit;
  const hasValidSourceCommit = /^[0-9a-f]{40}$/.test(sourceCommit ?? "");

  if (hasValidSourceCommit && !commitResolves(sourceCommit)) {
    fail(`${manifestFile}: source.commit does not resolve locally`);
  }
  if (hasValidSourceCommit && commitResolves(sourceCommit)) {
    if (!commitIsAncestorOfHead(sourceCommit)) {
      fail(
        `${manifestFile}: source.commit is not an ancestor of publication HEAD`,
      );
    } else if (sourceStatus === "release-ready") {
      validatePublicationChanges(sourceCommit, manifestFile, manifest.release);
    }
  }

  if (sourceStatus === "release-ready") {
    validateSourceProvenance(manifest, manifestFile, {
      sourceLabel: "release-ready",
      releaseReady: true,
    });
    if (gitOutput(["status", "--porcelain", "--untracked-files=all"])) {
      fail(`${manifestFile}: release-ready source requires a clean worktree`);
    }
    return "release-ready";
  }

  if (sourceStatus === "captured-clean-commit") {
    validateSourceProvenance(manifest, manifestFile, {
      sourceLabel: "captured clean",
      releaseReady: false,
    });
    return "visual-baseline";
  }

  fail(
    `${manifestFile}: source.status must be release-ready or captured-clean-commit`,
  );
  return "invalid";
}

function validateManifestMetadata(manifest, manifestFile) {
  if (manifest.schemaVersion !== 2) {
    fail(`${manifestFile}: schemaVersion must be 2`);
  }
  if (!/^v\d+\.\d+\.\d+-alpha\.\d+$/.test(manifest.release ?? "")) {
    fail(`${manifestFile}: release must be a versioned alpha tag`);
  }
  if (Number.isNaN(Date.parse(manifest.generatedAt ?? ""))) {
    fail(`${manifestFile}: generatedAt must be a valid timestamp`);
  }
  if (Number.isNaN(Date.parse(manifest.revalidatedAt ?? ""))) {
    fail(`${manifestFile}: revalidatedAt must be a valid date`);
  }
  if (manifest.proofModel?.kind !== "visual-ui-evidence") {
    fail(`${manifestFile}: proofModel.kind must be visual-ui-evidence`);
  }
}

function validateManifestVerification(manifest, manifestFile) {
  if (manifest.verification?.humanVisualInspection !== "passed") {
    fail(`${manifestFile}: human visual inspection is not passed`);
  }
  if (manifest.verification?.captureLogsPublished !== false) {
    fail(`${manifestFile}: captureLogsPublished must be false`);
  }
}

function manifestCaptures(manifest, manifestFile) {
  const captures = Array.isArray(manifest.captures) ? manifest.captures : [];
  if (captures.length === 0)
    fail(`${manifestFile}: captures must not be empty`);
  if (manifest.verification?.screenshotCount !== captures.length) {
    fail(`${manifestFile}: screenshotCount does not match captures length`);
  }
  return captures;
}

function validCaptureFilename(file) {
  return (
    typeof file === "string" &&
    !file.includes("/") &&
    extname(file).toLowerCase() === ".png"
  );
}

function validateCaptureContent(capture, file, data, manifestFile, hashes) {
  const metadata = pngMetadata(data, file);
  const sha256 = createHash("sha256").update(data).digest("hex");
  if (capture.sha256 !== sha256)
    fail(`${manifestFile}: checksum mismatch: ${file}`);
  if (hashes.has(sha256))
    fail(`${manifestFile}: duplicate image content: ${file}`);
  hashes.add(sha256);
  if (
    metadata &&
    (capture.width !== metadata.width || capture.height !== metadata.height)
  ) {
    fail(`${manifestFile}: dimensions mismatch: ${file}`);
  }
}

function validateCaptureFile(
  capture,
  expectedIndex,
  directory,
  manifestFile,
  hashes,
  declaredFiles,
) {
  if (capture.index !== expectedIndex) {
    fail(`${manifestFile}: capture index must be ${expectedIndex}`);
  }
  if (!["student", "teacher"].includes(capture.persona)) {
    fail(
      `${manifestFile}: invalid capture persona: ${String(capture.persona)}`,
    );
  }
  const expectedPlatform = capture.device?.startsWith("iPhone")
    ? "iOS"
    : capture.device?.startsWith("iPad")
      ? "iPadOS"
      : null;
  if (!expectedPlatform || !capture.os?.startsWith(`${expectedPlatform} `)) {
    fail(`${manifestFile}: device and OS metadata do not agree`);
  }

  const file = capture.file;
  if (!validCaptureFilename(file)) {
    fail(`${manifestFile}: invalid capture filename: ${String(file)}`);
    return;
  }
  if (declaredFiles.has(file))
    fail(`${manifestFile}: duplicate capture filename: ${file}`);
  declaredFiles.add(file);

  const absolute = resolve(directory, file);
  if (!existsSync(absolute) || !statSync(absolute).isFile()) {
    fail(`${manifestFile}: missing capture: ${file}`);
    return;
  }
  validateCaptureContent(
    capture,
    file,
    readFileSync(absolute),
    manifestFile,
    hashes,
  );
}

function validatePublishedCaptureFiles(manifestFile, declaredFiles) {
  const publicFiles = repositoryFiles(
    `${manifestFile.slice(0, manifestFile.lastIndexOf("/"))}/*`,
  );
  for (const file of publicFiles) {
    const name = file.slice(file.lastIndexOf("/") + 1);
    if (name.endsWith(".log"))
      fail(`${manifestFile}: published capture log: ${name}`);
    if (name.endsWith(".png") && !declaredFiles.has(name)) {
      fail(`${manifestFile}: undeclared PNG: ${name}`);
    }
  }
}

function approvedPngFiles(
  directory = resolve(root, "docs/assets/screenshots/approved"),
) {
  if (!existsSync(directory)) return [];
  const files = [];
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const entryPath = resolve(directory, entry.name);
    if (entry.isDirectory()) {
      files.push(...approvedPngFiles(entryPath));
    } else if (entry.name.toLowerCase().endsWith(".png")) {
      files.push(relative(root, entryPath));
    }
  }
  return files;
}

function validateScreenshotManifest(manifestFile, imageReferences) {
  const absoluteManifest = resolve(root, manifestFile);
  const manifest = readScreenshotManifest(absoluteManifest, manifestFile);
  if (!manifest) {
    return {
      captureCount: 0,
      sourceStatus: "invalid",
      humanReviewed: false,
    };
  }

  validateManifestMetadata(manifest, manifestFile);
  const sourceStatus = validateManifestSource(manifest, manifestFile);
  validateManifestVerification(manifest, manifestFile);
  const captures = manifestCaptures(manifest, manifestFile);
  const hashes = new Set();
  const declaredFiles = new Set();
  const directory = dirname(absoluteManifest);
  for (const [index, capture] of captures.entries()) {
    validateCaptureFile(
      capture,
      index + 1,
      directory,
      manifestFile,
      hashes,
      declaredFiles,
    );
  }
  validatePublishedCaptureFiles(manifestFile, declaredFiles);
  if (sourceStatus === "release-ready") {
    for (const file of declaredFiles) {
      const capturePath = relative(root, resolve(directory, file));
      if (!imageReferences.has(capturePath)) {
        fail(
          `${manifestFile}: release-ready capture is not referenced by public Markdown: ${file}`,
        );
      }
    }
  }

  return {
    captureCount: captures.length,
    captureFiles: new Set(
      [...declaredFiles].map((file) =>
        relative(root, resolve(directory, file)),
      ),
    ),
    sourceStatus,
    humanReviewed: manifest.verification?.humanVisualInspection === "passed",
  };
}

const markdown = validateMarkdown();
const manifests = repositoryFiles(
  "docs/assets/screenshots/approved/*/manifest.json",
);
let screenshotCount = 0;
let releaseReadyManifests = 0;
let releaseReadyCaptureCount = 0;
let visualBaselineManifests = 0;
const declaredCaptureFiles = new Set();
for (const manifest of manifests) {
  const result = validateScreenshotManifest(manifest, markdown.imageReferences);
  screenshotCount += result.captureCount;
  for (const captureFile of result.captureFiles ?? []) {
    declaredCaptureFiles.add(captureFile);
  }
  if (result.sourceStatus === "release-ready" && result.humanReviewed) {
    releaseReadyManifests += 1;
    releaseReadyCaptureCount += result.captureCount;
  }
  if (result.sourceStatus === "visual-baseline") visualBaselineManifests += 1;
}

const approvedPngs = approvedPngFiles();
for (const file of approvedPngs) {
  if (!declaredCaptureFiles.has(file)) {
    fail(`approved screenshot PNG is not declared by a manifest: ${file}`);
  }
}

if (releaseMode) {
  if (manifests.length !== 1) {
    fail(
      `release validation requires exactly one screenshot manifest; found ${manifests.length}`,
    );
  }
  if (releaseReadyManifests !== 1) {
    fail(
      `release validation requires exactly one release-ready screenshot manifest; found ${releaseReadyManifests}`,
    );
  }
  if (releaseReadyCaptureCount !== 12) {
    fail(
      `release validation requires exactly 12 captures in the release-ready manifest; found ${releaseReadyCaptureCount}`,
    );
  }
  if (approvedPngs.length !== 12) {
    fail(
      `release validation requires exactly 12 approved screenshot PNG files; found ${approvedPngs.length}`,
    );
  }
}

if (unknownArgs.length > 0) {
  fail(`unknown validator argument(s): ${unknownArgs.join(", ")}`);
}

if (failures.length > 0) {
  for (const failure of failures) console.error(`- ${failure}`);
  console.error(
    `Public documentation validation failed with ${failures.length} issue(s).`,
  );
  process.exit(1);
}

console.log(
  `Public documentation validation passed: ${markdown.markdownFiles} Markdown files, ` +
    `${markdown.markdownImages} image references, ${manifests.length} screenshot manifest(s), ` +
    `${screenshotCount} published visual captures ` +
    `(${releaseReadyManifests} release-ready manifest(s), ` +
    `${visualBaselineManifests} visual baseline manifest(s)).`,
);
