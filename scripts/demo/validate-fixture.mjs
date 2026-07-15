#!/usr/bin/env node
import { readFile } from "node:fs/promises";
import path from "node:path";

const rootFixturePath = path.resolve(
  process.cwd(),
  "demo/fixtures/mock-university.json",
);
const iosFixturePath = path.resolve(
  process.cwd(),
  "ios/ResonanceApp/Sources/Resources/mock-university.json",
);

const errors = [];

function assert(condition, message) {
  if (!condition) {
    errors.push(message);
  }
}

function isObject(value) {
  return (
    value !== null &&
    typeof value === "object" &&
    Array.isArray(value) === false
  );
}

function ensureDemoPrefix(items, fieldPath, idSelector = (item) => item.id) {
  for (const item of items) {
    const id = idSelector(item);
    if (typeof id !== "string" || !id.startsWith("demo_")) {
      errors.push(
        `Expected ${fieldPath} id to start with demo_: ${String(id)}`,
      );
    }
  }
}

async function main() {
  const [rootRaw, iosRaw] = await Promise.all([
    readFile(rootFixturePath, "utf8"),
    readFile(iosFixturePath, "utf8"),
  ]);

  const rootFixture = parseFixture(rootRaw, rootFixturePath);
  const iosFixture = parseFixture(iosRaw, iosFixturePath);
  validateFixture(rootFixture);
  assertFixturesMatch(rootFixture, iosFixture);
  reportValidation(rootFixture);
}

function parseFixture(raw, fixturePath) {
  try {
    return JSON.parse(raw);
  } catch (err) {
    throw new Error(`Failed to parse ${fixturePath}: ${err.message}`);
  }
}

function validateFixture(rootFixture) {
  assert(isObject(rootFixture.meta), "Missing object: meta");
  assert(
    typeof rootFixture.meta?.universityName === "string",
    "Missing string: meta.universityName",
  );
  assert(Array.isArray(rootFixture.users), "Missing array: users");
  assert(Array.isArray(rootFixture.courses), "Missing array: courses");
  assert(Array.isArray(rootFixture.memberships), "Missing array: memberships");
  assert(Array.isArray(rootFixture.entries), "Missing array: entries");
  assert(Array.isArray(rootFixture.artifacts), "Missing array: artifacts");
  assert(Array.isArray(rootFixture.feedback), "Missing array: feedback");

  validateFixturePrefixes(rootFixture);
  validateFixtureArtifacts(rootFixture);
  validateSubmittedEntries(rootFixture);
  validateFixtureFeedback(rootFixture);
}

function validateFixturePrefixes(rootFixture) {
  if (Array.isArray(rootFixture.users))
    ensureDemoPrefix(rootFixture.users, "users[]");
  if (Array.isArray(rootFixture.courses))
    ensureDemoPrefix(rootFixture.courses, "courses[]");
  if (Array.isArray(rootFixture.entries))
    ensureDemoPrefix(rootFixture.entries, "entries[]");
  if (Array.isArray(rootFixture.artifacts))
    ensureDemoPrefix(rootFixture.artifacts, "artifacts[]");
}

function validateFixtureArtifacts(rootFixture) {
  if (Array.isArray(rootFixture.artifacts)) {
    for (const artifact of rootFixture.artifacts) {
      assert(
        Number.isInteger(artifact.expectedSizeBytes) &&
          artifact.expectedSizeBytes > 0,
        `Artifact ${artifact.id} must have a positive expectedSizeBytes`,
      );
      assert(
        rootFixture.entries?.some((entry) => entry.id === artifact.entryId),
        `Artifact ${artifact.id} must reference an existing entry`,
      );
      if (artifact.uploadState === "uploaded") {
        assert(
          Boolean(artifact.storageKey) && Boolean(artifact.remoteUrl),
          `Uploaded artifact ${artifact.id} must have storage metadata`,
        );
        assert(
          artifact.uploadExpiresAt === null &&
            artifact.confirmationToken === null,
          `Uploaded artifact ${artifact.id} must not have an active upload slot`,
        );
      } else if (artifact.uploadState === "uploading") {
        assert(
          Boolean(artifact.storageKey) && Boolean(artifact.uploadExpiresAt),
          `Uploading artifact ${artifact.id} must have an upload slot`,
        );
      } else {
        assert(
          artifact.storageKey === null &&
            artifact.remoteUrl === null &&
            artifact.uploadExpiresAt === null &&
            artifact.confirmationToken === null,
          `Inactive artifact ${artifact.id} must not have active upload metadata`,
        );
      }
    }
  }
}

function validateSubmittedEntries(rootFixture) {
  if (Array.isArray(rootFixture.entries)) {
    assert(
      rootFixture.entries.filter((entry) => entry.status === "submitted")
        .length >= 2,
      "Expected at least two submitted entries",
    );
  }
}

function validateFixtureFeedback(rootFixture) {
  if (Array.isArray(rootFixture.feedback)) {
    ensureDemoPrefix(rootFixture.feedback, "feedback[]");
    for (const feedback of rootFixture.feedback) {
      if (Array.isArray(feedback.markers)) {
        ensureDemoPrefix(
          feedback.markers,
          `feedback[${feedback.id}].markers[]`,
        );
      } else {
        errors.push(`Expected markers array for feedback ${feedback.id}`);
      }

      let parentEntryId;
      if (feedback.targetType === "entry") {
        parentEntryId = feedback.targetId;
        assert(
          rootFixture.entries?.some((entry) => entry.id === feedback.targetId),
          `Feedback ${feedback.id} must target an existing entry`,
        );
      } else if (feedback.targetType === "artifact") {
        const artifact = rootFixture.artifacts?.find(
          (candidate) => candidate.id === feedback.targetId,
        );
        assert(
          Boolean(artifact),
          `Feedback ${feedback.id} must target an existing artifact`,
        );
        assert(
          Boolean(artifact?.entryId),
          `Feedback ${feedback.id} artifact target must resolve to a parent entry`,
        );
        parentEntryId = artifact?.entryId;
      } else {
        errors.push(
          `Feedback ${feedback.id} has invalid targetType: ${String(feedback.targetType)}`,
        );
      }
      assert(
        rootFixture.entries?.find((entry) => entry.id === parentEntryId)
          ?.status === "reviewed",
        `Feedback ${feedback.id} parent entry must be reviewed`,
      );
    }
  }
}

function assertFixturesMatch(rootFixture, iosFixture) {
  const rootCanonical = JSON.stringify(rootFixture);
  const iosCanonical = JSON.stringify(iosFixture);
  assert(
    rootCanonical === iosCanonical,
    "Root fixture and iOS fixture differ. Keep demo/fixtures/mock-university.json and ios/.../mock-university.json in sync.",
  );
}

function reportValidation(rootFixture) {
  if (errors.length > 0) {
    console.error("Demo fixture validation failed:");
    for (const message of errors) {
      console.error(`- ${message}`);
    }
    process.exit(1);
  }

  console.log("Demo fixture validation passed.");
  console.log(`University: ${rootFixture.meta.universityName}`);
  console.log(
    `Counts -> users:${rootFixture.users.length} courses:${rootFixture.courses.length} entries:${rootFixture.entries.length} artifacts:${rootFixture.artifacts.length} feedback:${rootFixture.feedback.length}`,
  );
}

main().catch((err) => {
  console.error(err.message ?? err);
  process.exit(1);
});
