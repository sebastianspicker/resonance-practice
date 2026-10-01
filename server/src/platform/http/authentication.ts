/** Authenticated-request contract shared by the identity preHandler and feature routes. */
import type { FastifyRequest } from 'fastify';
import { ErrorCodes } from './errorCodes.js';
import { ApiError } from './errors.js';

export type AuthenticatedUser = { id: string; role: 'student' | 'teacher' };

declare module 'fastify' {
  interface FastifyRequest {
    user?: AuthenticatedUser;
  }
}

/** Route preHandler that authenticates the request and sets `request.user`. */
export type RequireAuth = (request: FastifyRequest) => Promise<void>;

/** The user set by the RequireAuth preHandler; absence means the route was wired without it. */
export function authenticatedUser(request: FastifyRequest): AuthenticatedUser {
  if (!request.user) {
    throw new ApiError(401, ErrorCodes.MISSING_AUTH, 'Missing or invalid Authorization header');
  }
  return request.user;
}
