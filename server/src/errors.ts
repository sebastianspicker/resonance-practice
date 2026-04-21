import { FastifyReply } from 'fastify';
import { ErrorCodes } from './errorCodes.js';

export class ApiError extends Error {
  statusCode: number;
  code: string;
  details?: Record<string, unknown> | undefined;

  constructor(
    statusCode: number,
    code: string,
    message: string,
    details?: Record<string, unknown>
  ) {
    super(message);
    this.statusCode = statusCode;
    this.code = code;
    this.details = details;
  }
}

export function sendError(reply: FastifyReply, error: ApiError) {
  // Only expose safe detail fields to the client
  const safeDetails: Record<string, unknown> = {};
  if (error.details) {
    const allowedKeys = ['field', 'reason', 'expected', 'actual'];
    for (const key of allowedKeys) {
      if (error.details[key] !== undefined) {
        safeDetails[key] = error.details[key];
      }
    }
  }

  reply.code(error.statusCode).send({
    error: {
      code: error.code,
      message: error.message,
      details: safeDetails,
    },
  });
}

/**
 * Check whether an unknown error is a Prisma client known-request error
 * with the given code (e.g. 'P2002', 'P2025').
 */
export function isPrismaError(err: unknown, prismaCode: string): boolean {
  return (
    typeof err === 'object' &&
    err !== null &&
    'code' in err &&
    (err as { code: string }).code === prismaCode
  );
}

/**
 * Wrap a Prisma operation and translate known error codes into ApiErrors.
 * - P2002 (unique constraint) -> 409 ID_CONFLICT
 * - P2025 (record not found)  -> 404 NOT_FOUND
 */
export async function withPrismaErrors<T>(
  operation: () => Promise<T>,
  options?: {
    conflictMessage?: string;
    notFoundCode?: string;
    notFoundMessage?: string;
  }
): Promise<T> {
  try {
    return await operation();
  } catch (err: unknown) {
    if (isPrismaError(err, 'P2002')) {
      throw new ApiError(
        409,
        ErrorCodes.ID_CONFLICT,
        options?.conflictMessage ?? 'Resource already exists'
      );
    }
    if (isPrismaError(err, 'P2025')) {
      throw new ApiError(
        404,
        options?.notFoundCode ?? ErrorCodes.NOT_FOUND,
        options?.notFoundMessage ?? 'Resource not found'
      );
    }
    throw err;
  }
}
