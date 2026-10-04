import type { FastifyRequest } from 'fastify';
import { RateLimiterMemory } from 'rate-limiter-flexible';
import { config, limits } from '../config.js';
import { ErrorCodes } from './errorCodes.js';
import { ApiError } from './errors.js';

/** Default per-route request budget, matching the global rate-limit plugin defaults. */
export const apiRateLimit = {
  max: 100,
  timeWindow: '1 minute',
};

/**
 * Per-client request budgets enforced inside each route handler with
 * `limiter.consume(...)`, so every handler is visibly rate-limited.
 */
export const apiLimiter = new RateLimiterMemory({ points: apiRateLimit.max, duration: 60 });
export const authLimiter = new RateLimiterMemory({ points: limits.authRateLimitMax, duration: 60 });

export function isLoopback(ip: string | undefined) {
  return ip === '127.0.0.1' || ip === '::1' || ip === '::ffff:127.0.0.1';
}

/** Cost of one request: zero for local dev traffic, which the rate limit does not apply to. */
export function requestCost(request: FastifyRequest) {
  return config.authMode === 'dev' && isLoopback(request.ip) ? 0 : 1;
}

/** Maps a rejected `consume` call to the shared 429 API error. */
export function rejectRateLimited(): never {
  throw new ApiError(429, ErrorCodes.RATE_LIMITED, 'Too many requests. Please try again later.');
}
