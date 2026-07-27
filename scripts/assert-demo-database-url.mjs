#!/usr/bin/env node
// Guard destructive demo mutations to the local public resonance database.
import { pathToFileURL } from "node:url";

/** Limit destructive demo setup to the local `resonance` database. */
export function assertDemoDatabaseUrl(databaseUrl) {
  if (!databaseUrl) {
    throw new Error(
      "Refusing demo database mutation: DATABASE_URL must be set.",
    );
  }

  let parsed;
  try {
    parsed = new URL(databaseUrl);
  } catch {
    throw new Error(
      "Refusing demo database mutation: DATABASE_URL must be a valid URL.",
    );
  }

  if (parsed.protocol !== "postgresql:" && parsed.protocol !== "postgres:") {
    throw new Error(
      "Refusing demo database mutation: DATABASE_URL protocol must be postgresql: or postgres:.",
    );
  }

  const loopbackHosts = new Set(["localhost", "127.0.0.1", "::1"]);
  const hostname = parsed.hostname.replace(/^\[|\]$/g, "");
  if (!loopbackHosts.has(hostname)) {
    throw new Error(
      "Refusing demo database mutation: DATABASE_URL host must be loopback.",
    );
  }

  let databaseName;
  try {
    databaseName = decodeURIComponent(parsed.pathname).replace(/^\/+/, "");
  } catch {
    throw new Error(
      "Refusing demo database mutation: DATABASE_URL has an invalid database name.",
    );
  }
  if (databaseName !== "resonance") {
    throw new Error(
      'Refusing demo database mutation: DATABASE_URL database name must be "resonance".',
    );
  }

  if (
    parsed.searchParams.getAll("schema").some((schema) => schema !== "public")
  ) {
    throw new Error(
      'Refusing demo database mutation: DATABASE_URL schema must be "public".',
    );
  }
  if (
    parsed.searchParams.has("options") ||
    parsed.searchParams.has("search_path")
  ) {
    throw new Error(
      "Refusing demo database mutation: DATABASE_URL must not override search_path.",
    );
  }
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  try {
    assertDemoDatabaseUrl(process.env.DATABASE_URL);
    console.log(
      "Destructive demo database target verified: loopback/resonance",
    );
  } catch (error) {
    console.error(
      error instanceof Error
        ? error.message
        : "Refusing demo database mutation",
    );
    process.exitCode = 1;
  }
}
