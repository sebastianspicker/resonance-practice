#!/usr/bin/env node
// Guard destructive database operations by database/schema identity.
// Usage: node scripts/assert-database-target.mjs [--development]
import { pathToFileURL } from "node:url";

const REQUIRED_TEST_DATABASE = "resonance_test";
// WHATWG URL retains brackets around IPv6 hostnames (`[::1]`).
const LOOPBACK_HOSTS = new Set(["localhost", "127.0.0.1", "[::1]"]);

/** Shared URL parser for destructive local database operations. Never include credentials in errors. */
function assertDatabaseTargetUrl(rawUrl, { databaseName, purpose, allowExplicitRemote }) {
  const refuse = (reason) => new Error(`Refusing destructive ${purpose}: ${reason}`);
  const parsed = parsePostgresUrl(rawUrl, databaseName, refuse);
  assertApprovedHost(parsed.hostname, allowExplicitRemote, refuse);
  assertDatabaseName(parsed.pathname, databaseName, refuse);
  assertPublicSchema(parsed.searchParams, refuse);
}

function parsePostgresUrl(rawUrl, databaseName, refuse) {
  if (!rawUrl) throw refuse(`DATABASE_URL must name ${databaseName}`);
  let parsed;
  try {
    parsed = new URL(rawUrl);
  } catch {
    throw refuse("DATABASE_URL is invalid");
  }
  if (parsed.protocol !== "postgresql:" && parsed.protocol !== "postgres:") {
    throw refuse("DATABASE_URL must use PostgreSQL");
  }
  return parsed;
}

function assertApprovedHost(hostname, allowExplicitRemote, refuse) {
  if (LOOPBACK_HOSTS.has(hostname)) return;
  const remoteDatabaseAllowed = allowExplicitRemote &&
    process.env.RESONANCE_ALLOW_REMOTE_TEST_DATABASE === "true";
  if (remoteDatabaseAllowed && process.env.RESONANCE_TEST_DATABASE_HOST === hostname) return;
  throw refuse(
    `DATABASE_URL host must be loopback${allowExplicitRemote ? " or explicitly approved" : ""}`,
  );
}

function assertDatabaseName(pathname, expectedDatabaseName, refuse) {
  let databaseName;
  try {
    databaseName = decodeURIComponent(pathname.slice(1));
  } catch {
    throw refuse("DATABASE_URL has an invalid database name");
  }
  if (databaseName !== expectedDatabaseName) {
    throw refuse(`database must be ${expectedDatabaseName}`);
  }
}

function assertPublicSchema(searchParams, refuse) {
  if (searchParams.getAll("schema").some((schema) => schema !== "public")) {
    throw refuse("database schema must be public");
  }
  if (searchParams.has("options") || searchParams.has("search_path")) {
    throw refuse("DATABASE_URL must not override search_path");
  }
}

/** Fail closed before any destructive test-database operation. */
export function assertTestDatabaseUrl(rawUrl) {
  return assertDatabaseTargetUrl(rawUrl, {
    databaseName: REQUIRED_TEST_DATABASE,
    purpose: 'test setup',
    allowExplicitRemote: true,
  });
}

/** Fail closed unless the target is the local `resonance` development database. */
export function assertDevelopmentDatabaseUrl(rawUrl, purpose = 'development reset') {
  return assertDatabaseTargetUrl(rawUrl, {
    databaseName: 'resonance',
    purpose,
    allowExplicitRemote: false,
  });
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  const development = process.argv.includes("--development");
  try {
    if (development) {
      assertDevelopmentDatabaseUrl(process.env.DATABASE_URL, "development data mutation");
    } else {
      assertTestDatabaseUrl(process.env.DATABASE_URL);
    }
    console.log(
      `Destructive database target verified: ${development ? "resonance" : REQUIRED_TEST_DATABASE}`,
    );
  } catch (error) {
    console.error(
      error instanceof Error
        ? error.message
        : "Refusing destructive database operation",
    );
    process.exitCode = 1;
  }
}
