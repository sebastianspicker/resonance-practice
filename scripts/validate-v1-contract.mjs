#!/usr/bin/env node
/**
 * Validate the canonical v1 wire contract document and the iOS client's projection of it.
 */
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = fileURLToPath(new URL(".", import.meta.url));
const rootDirectory = new URL("..", `file://${scriptDirectory}`).pathname;
const contractPath = join(rootDirectory, "contracts/v1-api-contract.json");
const swiftArtifactModelsPath = join(
  rootDirectory,
  "ios/ResonanceApp/Sources/Core/Networking/APIArtifactModels.swift",
);
const swiftArtifactClientPath = join(
  rootDirectory,
  "ios/ResonanceApp/Sources/Core/Networking/APIClient+FeedbackSync.swift",
);
const swiftNetworkingDirectory = join(
  rootDirectory,
  "ios/ResonanceApp/Sources/Core/Networking",
);

const contract = JSON.parse(readFileSync(contractPath, "utf8"));

function fail(message) {
  throw new Error(`v1 contract: ${message}`);
}

function requireStringArray(value, label) {
  if (
    !Array.isArray(value) ||
    value.some((item) => typeof item !== "string" || item.length === 0)
  ) {
    fail(`${label} must be a non-empty string array`);
  }
  if (new Set(value).size !== value.length)
    fail(`${label} must not contain duplicates`);
  return value;
}

function sourceFiles(directory, extension = ".ts") {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = join(directory, entry.name);
    return entry.isDirectory()
      ? sourceFiles(path, extension)
      : entry.name.endsWith(extension)
        ? [path]
        : [];
  });
}

function assertEqualSet(actual, expected, label) {
  const actualValues = [...actual].sort();
  const expectedValues = [...expected].sort();
  if (JSON.stringify(actualValues) !== JSON.stringify(expectedValues)) {
    fail(`${label} differs from the canonical contract`);
  }
}

function typeFields(source, typeName, label) {
  const match = source.match(
    new RegExp(
      `(?:type\\s+${typeName}\\s*=|struct\\s+${typeName}[^\\{]*)\\{([\\s\\S]*?)\\n\\}`,
      "m",
    ),
  );
  if (!match?.[1]) fail(`could not locate ${label}`);
  return [...match[1].matchAll(/^\s*(?:let\s+)?(\w+)\??\s*:/gm)].map(
    (item) => item[1],
  );
}

if (contract.contractVersion !== "v1") fail("contractVersion must be v1");
if (!Array.isArray(contract.routes) || contract.routes.length === 0)
  fail("routes must be non-empty");
const contractRoutes = contract.routes.map((route) => {
  if (
    !route ||
    typeof route.method !== "string" ||
    typeof route.path !== "string"
  ) {
    fail("each route must have method and path");
  }
  if (!["GET", "POST", "PUT", "PATCH", "DELETE"].includes(route.method)) {
    fail(`unsupported method ${route.method}`);
  }
  if (!route.path.startsWith("/api/v1/"))
    fail(`route is not v1: ${route.path}`);
  return `${route.method} ${route.path}`;
});
if (new Set(contractRoutes).size !== contractRoutes.length)
  fail("routes must not contain duplicates");

const sync = contract.sync;
const reads = contract.reads;
if (!reads || reads.defaultPageSize !== 50 || reads.maxPageSize !== 200) {
  fail("read pagination must default to 50 and cap at 200");
}
assertEqualSet(reads.pageFields, ["items", "nextCursor"], "page envelope");
assertEqualSet(reads.pageQueryFields, ["limit", "cursor"], "page query fields");
if (JSON.stringify(reads.feedbackOrder) !== JSON.stringify(["createdAt:asc", "id:asc"])) {
  fail("feedback ordering must be stable ascending createdAt and id");
}
assertEqualSet(reads.reviewQueueOmittedFields, ["captureMarkers"], "review summary omissions");
if (!sync || sync.commandPath !== "/api/v1/sync/commands")
  fail("sync commandPath must be the v1 sync endpoint");
const commandFields = requireStringArray(
  sync.commandFields,
  "sync.commandFields",
);
const commandKinds = requireStringArray(sync.commandKinds, "sync.commandKinds");
const resultFields = requireStringArray(sync.resultFields, "sync.resultFields");
const resultStatuses = requireStringArray(
  sync.resultStatuses,
  "sync.resultStatuses",
);
const errorFields = requireStringArray(
  contract.errorEnvelope?.fields,
  "errorEnvelope.fields",
);
const artifactSessions = contract.artifactSessions;
if (!artifactSessions || typeof artifactSessions !== "object") {
  fail("artifactSessions must be an object");
}
const artifactSessionCreateRequestFields = requireStringArray(
  artifactSessions.createRequestFields,
  "artifactSessions.createRequestFields",
);
const artifactSessionCreateResponseFields = requireStringArray(
  artifactSessions.createResponseFields,
  "artifactSessions.createResponseFields",
);
const artifactSessionCompleteResponseFields = requireStringArray(
  artifactSessions.completeResponseFields,
  "artifactSessions.completeResponseFields",
);
const artifactDownloadResponseFields = requireStringArray(
  artifactSessions.downloadResponseFields,
  "artifactSessions.downloadResponseFields",
);
if (
  artifactSessions.checksumSha256?.encoding !== "padded-base64" ||
  artifactSessions.checksumSha256?.decodedByteLength !== 32
) {
  fail("artifactSessions.checksumSha256 must be padded base64 of 32 bytes");
}

const swiftNetworkingSource = sourceFiles(swiftNetworkingDirectory, ".swift")
  .map((file) => readFileSync(file, "utf8"))
  .join("\n");
for (const kind of commandKinds) {
  if (!new RegExp(`case ${kind}\\b`).test(swiftNetworkingSource)) {
    fail(`iOS sync command kind is missing ${kind}`);
  }
}
for (const status of resultStatuses) {
  if (!new RegExp(`case ${status}\\b`).test(swiftNetworkingSource)) {
    fail(`iOS sync result status is missing ${status}`);
  }
}
for (const field of errorFields) {
  if (!new RegExp(`let ${field}:`).test(swiftNetworkingSource)) {
    fail(`iOS error DTO is missing ${field}`);
  }
}

const swiftArtifactModels = readFileSync(swiftArtifactModelsPath, "utf8");
const swiftArtifactClient = readFileSync(swiftArtifactClientPath, "utf8");
assertEqualSet(
  typeFields(
    swiftArtifactModels,
    "ArtifactSessionRequest",
    "iOS artifact create request DTO",
  ),
  [
    "operationId",
    "entryId",
    "artifact",
    "sizeBytes",
    "checksumSha256",
    "baseVersion",
  ],
  "iOS artifact create request DTO fields",
);
assertEqualSet(
  typeFields(
    swiftArtifactModels,
    "ArtifactSessionCreateResponse",
    "iOS artifact create response DTO",
  ),
  artifactSessionCreateResponseFields,
  "iOS artifact create response DTO fields",
);
assertEqualSet(
  typeFields(
    swiftArtifactModels,
    "ArtifactSessionCompletionResponse",
    "iOS artifact complete response DTO",
  ),
  artifactSessionCompleteResponseFields,
  "iOS artifact complete response DTO fields",
);
assertEqualSet(
  typeFields(
    swiftArtifactModels,
    "ArtifactDownloadResponse",
    "iOS artifact download response DTO",
  ),
  artifactDownloadResponseFields,
  "iOS artifact download response DTO fields",
);
for (const field of artifactSessionCreateRequestFields) {
  if (field === "artifactId" || field === "type" || field === "durationSeconds")
    continue;
  if (!new RegExp(`let ${field}:`).test(swiftArtifactClient)) {
    fail(`iOS artifact request body is missing ${field}`);
  }
}
if (!swiftArtifactClient.includes("let checksumSha256: String")) {
  fail("iOS artifact request must expose checksumSha256 as a string");
}

console.log(
  `v1 contract valid: ${contractRoutes.length} routes, ${commandKinds.length} command kinds, artifact sessions`,
);
