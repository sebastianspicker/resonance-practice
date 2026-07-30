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
assert.equal(javascript.includes("/tmp/"), false);

const commandButtonLines = javascript
  .split("\n")
  .filter((line) => line.includes("<button") && line.includes("data-command="));
assert.ok(commandButtonLines.length > 0, "Expected simulated command controls");

for (const line of commandButtonLines) {
  assert.match(line, /simulationTag\(\)/, `Command control is missing its simulated marker: ${line.trim()}`);
}

const submitButtonLines = javascript
  .split("\n")
  .filter((line) => line.includes("<button") && line.includes('type="submit"'));
assert.ok(submitButtonLines.length > 0, "Expected a simulated feedback submission control");

for (const line of submitButtonLines) {
  assert.match(line, /simulationTag\(\)/, `Submit control is missing its simulated marker: ${line.trim()}`);
}

console.log("Static demo validation passed.");
