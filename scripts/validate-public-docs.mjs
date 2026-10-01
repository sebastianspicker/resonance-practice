#!/usr/bin/env node

// Check that public Markdown links and images stay inside the repository and
// resolve to files that are eligible for publication. Images require alt text.

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, realpathSync } from "node:fs";
import { dirname, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const failures = [];

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

function isInsideRoot(path) {
  return path === root || path.startsWith(`${root}/`);
}

function localTarget(rawTarget) {
  let target = rawTarget.trim();
  if (target.startsWith("<") && target.endsWith(">")) {
    target = target.slice(1, -1);
  }
  target = target.split("#", 1)[0].split("?", 1)[0];
  if (!target || /^(?:https?:|mailto:|tel:)/i.test(target)) return null;
  return decodeURIComponent(target);
}

const publicationCandidates = new Set(repositoryFiles("."));
const markdownFiles = repositoryFiles("*.md");
let linksChecked = 0;

for (const file of markdownFiles) {
  const absolute = resolve(root, file);
  const content = readFileSync(absolute, "utf8");
  const links = /(!?)\[([^\]]*)\]\(([^)]+)\)/g;

  for (const match of content.matchAll(links)) {
    const [, image, label, rawTarget] = match;
    if (image && !label.trim())
      failures.push(`${file}: image alt text is empty`);

    let target;
    try {
      target = localTarget(rawTarget);
    } catch {
      failures.push(`${file}: link target is not valid URI text: ${rawTarget}`);
      continue;
    }
    if (target === null) continue;
    linksChecked += 1;

    const resolved = resolve(dirname(absolute), target);
    if (!isInsideRoot(resolved) || !existsSync(resolved)) {
      failures.push(`${file}: local link does not resolve: ${rawTarget}`);
      continue;
    }

    const real = realpathSync(resolved);
    if (!isInsideRoot(real)) {
      failures.push(`${file}: local link escapes the repository: ${rawTarget}`);
      continue;
    }

    if (!publicationCandidates.has(relative(root, real))) {
      failures.push(
        `${file}: local link resolves to a file excluded from publication: ${rawTarget}`,
      );
    }
  }
}

if (failures.length > 0) {
  for (const failure of failures) console.error(failure);
  process.exit(1);
}

console.log(
  `Public documentation validation passed: ${markdownFiles.length} Markdown files, ${linksChecked} local links.`,
);
