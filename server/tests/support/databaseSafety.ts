// Re-exports the production-equivalent database guard for test setup and focused assertions.
export {
  assertDevelopmentDatabaseUrl,
  assertTestDatabaseUrl,
} from '../../../scripts/assert-database-target.mjs';
