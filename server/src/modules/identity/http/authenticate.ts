/** Bearer access-token authentication for protected routes. */
import type { FastifyRequest } from 'fastify';
import { ErrorCodes } from '../../../platform/http/errorCodes.js';
import { ApiError } from '../../../platform/http/errors.js';
import { verifyAccessToken } from '../application/auth.js';

export async function requireAuth(request: FastifyRequest): Promise<void> {
  const header = request.headers.authorization;
  if (!header || !header.startsWith('Bearer ')) {
    throw new ApiError(401, ErrorCodes.MISSING_AUTH, 'Missing or invalid Authorization header');
  }
  const payload = verifyAccessToken(header.slice(7));
  const userId = payload.sub as string | undefined;
  const role = payload.role as 'student' | 'teacher' | undefined;
  if (!userId || !role) {
    throw new ApiError(401, ErrorCodes.INVALID_TOKEN, 'Invalid token payload');
  }
  request.user = { id: userId, role };
}
