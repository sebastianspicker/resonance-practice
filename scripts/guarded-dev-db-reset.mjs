#!/usr/bin/env node
// Refuse reset unless the exact local development target and explicit operator confirmation are present.
import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { resolve } from 'node:path';
import { assertDevelopmentDatabaseUrl } from './assert-database-target.mjs';

const CONFIRMATION_VARIABLE = 'RESONANCE_CONFIRM_DEV_DB_RESET';
const REQUIRED_CONFIRMATION = 'RESET_DEVELOPMENT_DATABASE';

function refuse(message) {
  console.error(message);
  process.exitCode = 1;
}

try {
  if (process.env.AUTH_MODE !== 'dev') {
    throw new Error('Refusing destructive development reset: AUTH_MODE must be exactly dev');
  }
  assertDevelopmentDatabaseUrl(process.env.DATABASE_URL);
  if (process.env[CONFIRMATION_VARIABLE] !== REQUIRED_CONFIRMATION) {
    throw new Error(
      `Refusing destructive development reset: set ${CONFIRMATION_VARIABLE}=${REQUIRED_CONFIRMATION}`
    );
  }
} catch (error) {
  refuse(error instanceof Error ? error.message : 'Refusing destructive development reset');
}

if (!process.exitCode) {
  const prismaBinary = resolve(process.cwd(), 'node_modules/.bin/prisma');
  if (!existsSync(prismaBinary)) {
    refuse('Refusing destructive development reset: local Prisma CLI is unavailable');
  }
  if (process.exitCode) process.exit();
  const result = spawnSync(prismaBinary, ['migrate', 'reset', '--force'], {
    cwd: process.cwd(),
    env: process.env,
    stdio: 'inherit',
  });
  process.exitCode = result.status ?? 1;
}
