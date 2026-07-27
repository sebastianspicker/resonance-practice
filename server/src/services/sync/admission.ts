/** Process-local admission control that protects ordered v1 sync execution. */
import { ErrorCodes } from '../../errorCodes.js';
import { ApiError } from '../../errors.js';

const WINDOW_MS = 60_000;
export const MAX_SYNC_REQUESTS_PER_MINUTE = 12;
export const MAX_SYNC_COMMANDS_PER_MINUTE = 100;

type WindowUsage = { startedAt: number; requests: number; commands: number };

/**
 * Process-local admission guard for authenticated sync traffic. Persistent
 * receipt quotas remain the cross-process backstop; this prevents one active
 * client from consuming unbounded database work within a single minute.
 */
export function createSyncAdmission(now: () => number = Date.now) {
  const usageByUser = new Map<string, WindowUsage>();

  function usageFor(userId: string): WindowUsage {
    const current = now();
    for (const [knownUserId, usage] of usageByUser) {
      if (current - usage.startedAt >= WINDOW_MS) usageByUser.delete(knownUserId);
    }
    const existing = usageByUser.get(userId);
    if (existing && current - existing.startedAt < WINDOW_MS) return existing;
    const usage = { startedAt: current, requests: 0, commands: 0 };
    usageByUser.set(userId, usage);
    return usage;
  }

  return {
    admitRequest(userId: string): void {
      const usage = usageFor(userId);
      if (usage.requests >= MAX_SYNC_REQUESTS_PER_MINUTE) {
        throw new ApiError(
          429,
          ErrorCodes.RATE_LIMITED,
          'Too many sync requests; please try again later'
        );
      }
      usage.requests += 1;
    },
    admitCommands(userId: string, count: number): void {
      const usage = usageFor(userId);
      if (usage.commands + count > MAX_SYNC_COMMANDS_PER_MINUTE) {
        throw new ApiError(
          429,
          ErrorCodes.RATE_LIMITED,
          'Too many sync commands; please try again later'
        );
      }
      usage.commands += count;
    },
  };
}
