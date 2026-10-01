const DEFAULT_STORAGE_DELETION_BATCH_SIZE = 100;
const MAX_STORAGE_DELETION_BATCH_SIZE = 1000;

export type CleanupOptions = { limit?: number; now?: Date };

export function resolveCleanupOptions(options: CleanupOptions) {
  return {
    now: options.now ?? new Date(),
    limit: boundedStorageDeletionLimit(options.limit),
  };
}

export function boundedStorageDeletionLimit(limit?: number) {
  return Math.min(
    Math.max(limit ?? DEFAULT_STORAGE_DELETION_BATCH_SIZE, 1),
    MAX_STORAGE_DELETION_BATCH_SIZE
  );
}
