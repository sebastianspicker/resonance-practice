#!/usr/bin/env node

// Enforce the repository Node major version before local or CI workflows run.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const repositoryRoot = resolve(scriptDirectory, "..");
const expectedMajor = Number.parseInt(
  readFileSync(resolve(repositoryRoot, ".nvmrc"), "utf8").trim(),
  10,
);
const actualMajor = Number.parseInt(process.versions.node.split(".")[0] ?? "", 10);

if (!Number.isInteger(expectedMajor) || !Number.isInteger(actualMajor)) {
  console.error("Unable to determine the required or active Node.js major version.");
  process.exit(1);
}

if (actualMajor !== expectedMajor) {
  console.error(
    `Node.js ${expectedMajor}.x is required; active runtime is ${process.version}.`,
  );
  process.exit(1);
}

console.log(`Node.js runtime verified: ${process.version}`);
