// Type declarations for the destructive-database guards shared with server TypeScript.
export function assertTestDatabaseUrl(rawUrl: string | undefined): void;
export function assertDevelopmentDatabaseUrl(rawUrl: string | undefined, purpose?: string): void;
