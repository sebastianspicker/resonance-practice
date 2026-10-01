#!/usr/bin/env node
/** Generate the XCTest projection from the canonical JSON contract. */
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const scriptDirectory = fileURLToPath(new URL(".", import.meta.url));
const rootDirectory = new URL("..", `file://${scriptDirectory}`).pathname;
const contractPath = `${rootDirectory}contracts/v1-api-contract.json`;
const swiftTestPath = `${rootDirectory}ios/ResonanceApp/Tests/NetworkingContracts/APIClientSyncCommandTests.swift`;
const startMarker = "// v1-contract-projection:start";
const endMarker = "// v1-contract-projection:end";

const contract = JSON.parse(readFileSync(contractPath, "utf8"));
const fingerprint = createHash("sha256")
  .update(JSON.stringify(contract))
  .digest("hex");

function swiftStrings(values) {
  return values.map((value) => `      \"${value}\",`).join("\n");
}

function routeTuples(routes) {
  return routes
    .map(({ method, path }) => `      (\"${method}\", \"${path}\"),`)
    .join("\n");
}

const projection = `${startMarker}
  // Generated from contracts/v1-api-contract.json. Do not edit by hand; run
  // node scripts/generate-v1-contract-projection.mjs --write after contract changes.
  private enum V1APIContractProjection {
    static let fingerprint = \"${fingerprint}\"
    static let routes: [(String, String)] = [
${routeTuples(contract.routes)}
    ]
    static let commandFields = [
${swiftStrings(contract.sync.commandFields)}
    ]
    static let pageFields = [
${swiftStrings(contract.reads.pageFields)}
    ]
    static let defaultPageSize = ${contract.reads.defaultPageSize}
    static let maxPageSize = ${contract.reads.maxPageSize}
    static let feedbackOrder = [
${swiftStrings(contract.reads.feedbackOrder)}
    ]
    static let reviewQueueOmittedFields = [
${swiftStrings(contract.reads.reviewQueueOmittedFields)}
    ]
    static let commandKinds = [
${swiftStrings(contract.sync.commandKinds)}
    ]
    static let resultFields = [
${swiftStrings(contract.sync.resultFields)}
    ]
    static let resultStatuses = [
${swiftStrings(contract.sync.resultStatuses)}
    ]
    static let artifactSessionCreateRequestFields = [
${swiftStrings(contract.artifactSessions.createRequestFields)}
    ]
    static let artifactSessionChecksumEncoding = "${contract.artifactSessions.checksumSha256.encoding}"
    static let artifactSessionChecksumDecodedByteLength = ${contract.artifactSessions.checksumSha256.decodedByteLength}
    static let artifactSessionCreateResponseFields = [
${swiftStrings(contract.artifactSessions.createResponseFields)}
    ]
    static let artifactSessionCompleteResponseFields = [
${swiftStrings(contract.artifactSessions.completeResponseFields)}
    ]
    static let artifactDownloadResponseFields = [
${swiftStrings(contract.artifactSessions.downloadResponseFields)}
    ]
    static let errorFields = [
${swiftStrings(contract.errorEnvelope.fields)}
    ]
  }
  ${endMarker}`;

const swiftSource = readFileSync(swiftTestPath, "utf8");
const start = swiftSource.indexOf(startMarker);
const end = swiftSource.indexOf(endMarker);
if (start === -1 || end === -1 || end < start) {
  throw new Error(`Missing ${startMarker}/${endMarker} in ${swiftTestPath}`);
}
const expected = `${swiftSource.slice(0, start)}${projection}${swiftSource.slice(end + endMarker.length)}`;

if (process.argv.includes("--write")) {
  writeFileSync(swiftTestPath, expected);
} else if (swiftSource !== expected) {
  throw new Error(
    "XCTest contract projection is stale. Run node scripts/generate-v1-contract-projection.mjs --write.",
  );
}
