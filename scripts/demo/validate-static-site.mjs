import assert from "node:assert/strict";
import { access, readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(scriptDirectory, "../..");
const siteDirectory = path.join(repositoryRoot, "demo/site");

// Keep the published walkthrough self-contained and presentation-only.
const siteFiles = ["index.html", "styles.css", "demo.js"];
await Promise.all(siteFiles.map((file) => access(path.join(siteDirectory, file))));

const [html, css, javascript, readme] = await Promise.all([
  readFile(path.join(siteDirectory, "index.html"), "utf8"),
  readFile(path.join(siteDirectory, "styles.css"), "utf8"),
  readFile(path.join(siteDirectory, "demo.js"), "utf8"),
  readFile(path.join(repositoryRoot, "README.md"), "utf8"),
]);

assert.match(html, /Every command is simulated/);
assert.match(html, /does not connect\s+to an account, API, database, microphone, camera, or storage service/);
assert.match(html, /\.\/styles\.css/);
assert.match(html, /\.\/demo\.js/);
assert.match(css, /--accent:\s*#5e3fc4/i);
assert.match(readme, /https:\/\/sebastianspicker\.github\.io\/resonance\//);

const forbiddenOperationalFields = [
  "localPath",
  "storageKey",
  "remoteUrl",
  "expectedSizeBytes",
  "uploadExpiresAt",
  "confirmationToken",
  "retryCount",
  "lastError",
];

for (const field of forbiddenOperationalFields) {
  assert.equal(
    javascript.includes(field),
    false,
    `Static presentation fixture must not contain operational field ${field}`,
  );
}

assert.equal(javascript.includes("example.invalid"), false);
assert.equal(javascript.includes(["/", "tmp/"].join("")), false);

const unsafeMarkupSinks = [
  ["inner", "HTML"],
  ["outer", "HTML"],
  ["insertAdjacent", "HTML"],
  ["document", ".write"],
].map((parts) => parts.join(""));

for (const sink of unsafeMarkupSinks) {
  assert.equal(javascript.includes(sink), false, `Static demo must not use ${sink}`);
}

assert.match(javascript, /function commandButton\(/, "Expected simulated command controls");
assert.match(javascript, /function simulationTag\(/, "Expected simulated control markers");
assert.match(javascript, /type: "submit"/, "Expected a simulated feedback submission control");
assert.match(javascript, /simulationTag\(\)\);/, "Submit control is missing its simulated marker");

globalThis.console.log("Static demo validation passed.");
