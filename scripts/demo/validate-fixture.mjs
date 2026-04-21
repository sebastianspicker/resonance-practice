#!/usr/bin/env node
import { readFile } from 'node:fs/promises';
import path from 'node:path';

const rootFixturePath = path.resolve(process.cwd(), 'demo/fixtures/mock-university.json');
const iosFixturePath = path.resolve(process.cwd(), 'ios/ResonanceApp/Sources/Resources/mock-university.json');

const errors = [];

function assert(condition, message) {
  if (!condition) {
    errors.push(message);
  }
}

function isObject(value) {
  return value !== null && typeof value === 'object' && Array.isArray(value) === false;
}

function ensureDemoPrefix(items, fieldPath, idSelector = (item) => item.id) {
  for (const item of items) {
    const id = idSelector(item);
    if (typeof id !== 'string' || !id.startsWith('demo_')) {
      errors.push(`Expected ${fieldPath} id to start with demo_: ${String(id)}`);
    }
  }
}

async function main() {
  const [rootRaw, iosRaw] = await Promise.all([
    readFile(rootFixturePath, 'utf8'),
    readFile(iosFixturePath, 'utf8')
  ]);

  let rootFixture;
  let iosFixture;
  try {
    rootFixture = JSON.parse(rootRaw);
  } catch (err) {
    throw new Error(`Failed to parse ${rootFixturePath}: ${err.message}`);
  }
  try {
    iosFixture = JSON.parse(iosRaw);
  } catch (err) {
    throw new Error(`Failed to parse ${iosFixturePath}: ${err.message}`);
  }

  assert(isObject(rootFixture.meta), 'Missing object: meta');
  assert(typeof rootFixture.meta?.universityName === 'string', 'Missing string: meta.universityName');
  assert(Array.isArray(rootFixture.users), 'Missing array: users');
  assert(Array.isArray(rootFixture.courses), 'Missing array: courses');
  assert(Array.isArray(rootFixture.memberships), 'Missing array: memberships');
  assert(Array.isArray(rootFixture.entries), 'Missing array: entries');
  assert(Array.isArray(rootFixture.artifacts), 'Missing array: artifacts');
  assert(Array.isArray(rootFixture.feedback), 'Missing array: feedback');

  if (Array.isArray(rootFixture.users)) ensureDemoPrefix(rootFixture.users, 'users[]');
  if (Array.isArray(rootFixture.courses)) ensureDemoPrefix(rootFixture.courses, 'courses[]');
  if (Array.isArray(rootFixture.entries)) ensureDemoPrefix(rootFixture.entries, 'entries[]');
  if (Array.isArray(rootFixture.artifacts)) ensureDemoPrefix(rootFixture.artifacts, 'artifacts[]');
  if (Array.isArray(rootFixture.feedback)) {
    ensureDemoPrefix(rootFixture.feedback, 'feedback[]');
    for (const feedback of rootFixture.feedback) {
      if (Array.isArray(feedback.markers)) {
        ensureDemoPrefix(feedback.markers, `feedback[${feedback.id}].markers[]`);
      } else {
        errors.push(`Expected markers array for feedback ${feedback.id}`);
      }
    }
  }

  const rootCanonical = JSON.stringify(rootFixture);
  const iosCanonical = JSON.stringify(iosFixture);
  assert(
    rootCanonical === iosCanonical,
    'Root fixture and iOS fixture differ. Keep demo/fixtures/mock-university.json and ios/.../mock-university.json in sync.'
  );

  if (errors.length > 0) {
    console.error('Demo fixture validation failed:');
    for (const message of errors) {
      console.error(`- ${message}`);
    }
    process.exit(1);
  }

  console.log('Demo fixture validation passed.');
  console.log(`University: ${rootFixture.meta.universityName}`);
  console.log(
    `Counts -> users:${rootFixture.users.length} courses:${rootFixture.courses.length} entries:${rootFixture.entries.length} artifacts:${rootFixture.artifacts.length} feedback:${rootFixture.feedback.length}`
  );
}

main().catch((err) => {
  console.error(err.message ?? err);
  process.exit(1);
});
