#!/usr/bin/env node
// Enforce the iOS source-layer dependency direction from declarations, not name lists.
//
// Layers live in ios/ResonanceApp/Sources/{App,Core,Features,SharedUI}. A file may
// reference types declared in its own layer or in a layer it is allowed to use:
//   Core     -> (nothing above it)
//   SharedUI -> Core
//   Features -> Core, SharedUI
//   App      -> everything
// Only top-level (unindented) declarations count, so nested names such as `Body`
// never map to a layer. Type names declared in more than one layer are ambiguous
// and never reported.
//
// Usage: check-ios-layers.mjs [sources-root] | --self-test

import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const ALLOWED = {
  Core: [],
  SharedUI: ["Core"],
  Features: ["Core", "SharedUI"],
  App: ["Core", "SharedUI", "Features"],
};
const LAYERS = Object.keys(ALLOWED);
const DECLARATION =
  /^(?:@[\w.]+(?:\([^)]*\))?[ \t]+)*((?:(?:public|internal|private|fileprivate|final|open|indirect|nonisolated)[ \t]+)*)(?:class|struct|enum|actor|protocol|typealias)[ \t]+([A-Z]\w*)/gm;

function swiftFiles(directory) {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) return swiftFiles(path);
    return entry.name.endsWith(".swift") ? [path] : [];
  });
}

/** Remove comments and string literal contents so prose never counts as a dependency. */
function codeOnly(source) {
  return source
    .replace(/"""[\s\S]*?"""/g, '""')
    .replace(/\/\*[\s\S]*?\*\//g, " ")
    .replace(/\/\/.*$/gm, "")
    .replace(/"(?:\\.|[^"\\\n])*"/g, '""');
}

export function findLayerViolations(sourcesRoot) {
  const files = LAYERS.flatMap((layer) =>
    swiftFiles(join(sourcesRoot, layer)).map((path) => ({
      layer,
      path,
      code: codeOnly(readFileSync(path, "utf8")),
    })),
  );

  const declaringLayers = new Map();
  for (const file of files) {
    for (const [, modifiers, name] of file.code.matchAll(DECLARATION)) {
      if (/\b(?:private|fileprivate)\b/.test(modifiers)) continue;
      if (!declaringLayers.has(name)) declaringLayers.set(name, new Set());
      declaringLayers.get(name).add(file.layer);
    }
  }

  const violations = [];
  for (const file of files) {
    const permitted = new Set([file.layer, ...ALLOWED[file.layer]]);
    const lines = file.code.split("\n");
    lines.forEach((line, index) => {
      for (const [name] of line.matchAll(/\b[A-Z]\w*\b/g)) {
        const owners = declaringLayers.get(name);
        if (!owners || owners.size !== 1) continue;
        const [owner] = owners;
        if (permitted.has(owner)) continue;
        violations.push({
          file: relative(sourcesRoot, file.path),
          line: index + 1,
          symbol: name,
          from: file.layer,
          to: owner,
        });
      }
    });
  }
  return violations;
}

function writeFixture(root, files) {
  for (const [path, source] of Object.entries(files)) {
    mkdirSync(dirname(join(root, path)), { recursive: true });
    writeFileSync(join(root, path), source);
  }
}

/** Checks the checker against one violating and one clean fixture tree. */
function selfTest() {
  const violating = {
    "Core/Store.swift": [
      "// EditorDraft in a comment never counts.",
      "struct Store {",
      "    let label = \"Shell\"",
      "    let response: Response?",
      "    let config: Config?",
      "    let draft: EditorDraft",
      "}",
      "",
    ].join("\n"),
    "SharedUI/Theme.swift": "enum Theme {}\n",
    "Features/Editor.swift": [
      "struct EditorDraft {",
      "    struct Response {}",
      "}",
      "struct Config {}",
      "struct EditorView {",
      "    let shell: Shell",
      "}",
      "",
    ].join("\n"),
    "App/Shell.swift": [
      "@MainActor",
      "final class Shell {",
      "    let view: EditorView",
      "    let store: Store",
      "    let theme: Theme",
      "}",
      "struct Config {}",
      "",
    ].join("\n"),
  };
  const clean = {
    "Core/Store.swift": "struct Store {}\n",
    "SharedUI/Theme.swift": "enum Theme {\n    static let store: Store? = nil\n}\n",
    "Features/Editor.swift": "struct EditorView {\n    let store: Store\n    let theme: Theme\n}\n",
    "App/Shell.swift": "struct Shell {\n    let view: EditorView\n}\n",
  };
  const cases = [
    {
      name: "violating fixture",
      files: violating,
      expected: [
        "Core/Store.swift:6: Core -> Features (EditorDraft)",
        "Features/Editor.swift:6: Features -> App (Shell)",
      ],
    },
    { name: "clean fixture", files: clean, expected: [] },
  ];

  let failed = false;
  for (const testCase of cases) {
    const root = mkdtempSync(join(tmpdir(), "resonance-ios-layers-"));
    try {
      writeFixture(root, testCase.files);
      const actual = findLayerViolations(root)
        .map((v) => `${v.file}:${v.line}: ${v.from} -> ${v.to} (${v.symbol})`)
        .sort();
      const expected = [...testCase.expected].sort();
      if (JSON.stringify(actual) !== JSON.stringify(expected)) {
        failed = true;
        console.error(`iOS layer self-test failed for ${testCase.name}.`);
        console.error(`  expected: ${JSON.stringify(expected)}`);
        console.error(`  actual:   ${JSON.stringify(actual)}`);
      }
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  }
  if (failed) process.exit(1);
  console.log("iOS layer self-test passed.");
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  if (process.argv[2] === "--self-test") {
    selfTest();
  } else {
    const repositoryRoot = join(fileURLToPath(new URL(".", import.meta.url)), "..");
    const sourcesRoot = process.argv[2] ?? join(repositoryRoot, "ios/ResonanceApp/Sources");
    const violations = findLayerViolations(sourcesRoot);
    for (const v of violations) {
      console.error(`${v.file}:${v.line}: ${v.from} must not depend on ${v.to} (${v.symbol})`);
    }
    if (violations.length > 0) {
      console.error(`iOS layer check failed: ${violations.length} violation(s).`);
      process.exit(1);
    }
    console.log("iOS layer check passed.");
  }
}
