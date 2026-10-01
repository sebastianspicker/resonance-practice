/** Typed API errors and the single error-response translation boundary. */
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

export function sendError(reply: FastifyReply, error: ApiError, requestId?: string) {
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
      ...(requestId ? { requestId } : {}),
      ...(error.code === ErrorCodes.VERSION_CONFLICT && typeof safeDetails.actual === 'number'
        ? { currentVersion: safeDetails.actual }
        : {}),
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
