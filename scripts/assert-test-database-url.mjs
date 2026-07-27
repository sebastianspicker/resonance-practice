#!/usr/bin/env node
// Guard destructive setup by test database/schema identity while allowing explicit remote test hosts.
import { pathToFileURL } from "node:url";

const REQUIRED_TEST_DATABASE = "resonance_test";

/** Fail closed before any destructive test-database operation. */
export function assertTestDatabaseUrl(rawUrl) {
  if (!rawUrl) {
    throw new Error(
      `Refusing destructive test setup: DATABASE_URL must name ${REQUIRED_TEST_DATABASE}`,
    );
  }

  let parsed;
  try {
    parsed = new URL(rawUrl);
  } catch {
    throw new Error("Refusing destructive test setup: DATABASE_URL is invalid");
  }
  if (parsed.protocol !== "postgresql:" && parsed.protocol !== "postgres:") {
    throw new Error(
      "Refusing destructive test setup: DATABASE_URL must use PostgreSQL",
    );
  }

  let databaseName;
  try {
    databaseName = decodeURIComponent(parsed.pathname.replace(/^\//, ""));
  } catch {
    throw new Error(
      "Refusing destructive test setup: DATABASE_URL has an invalid database name",
    );
  }
  if (databaseName !== REQUIRED_TEST_DATABASE) {
    throw new Error(
      `Refusing destructive test setup: database must be ${REQUIRED_TEST_DATABASE}`,
    );
  }
  if (
    parsed.searchParams.getAll("schema").some((schema) => schema !== "public")
  ) {
    throw new Error(
      "Refusing destructive test setup: database schema must be public",
    );
  }
  if (
    parsed.searchParams.has("options") ||
    parsed.searchParams.has("search_path")
  ) {
    throw new Error(
      "Refusing destructive test setup: DATABASE_URL must not override search_path",
    );
  }
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  try {
    assertTestDatabaseUrl(process.env.DATABASE_URL);
    console.log(
      `Destructive database target verified: ${REQUIRED_TEST_DATABASE}`,
    );
  } catch (error) {
    console.error(
      error instanceof Error
        ? error.message
        : "Refusing destructive test setup",
    );
    process.exitCode = 1;
  }
}
