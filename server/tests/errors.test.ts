import { describe, expect, it } from 'vitest';
import { ApiError, sendError } from '../src/errors.js';

describe('errors (unit)', () => {
  // ── ApiError construction ──

  describe('ApiError', () => {
    it('constructs with status code, code, and message', () => {
      const err = new ApiError(400, 'VALIDATION_ERROR', 'Bad input');
      expect(err).toBeInstanceOf(Error);
      expect(err).toBeInstanceOf(ApiError);
      expect(err.statusCode).toBe(400);
      expect(err.code).toBe('VALIDATION_ERROR');
      expect(err.message).toBe('Bad input');
      expect(err.details).toBeUndefined();
    });

    it('constructs with details', () => {
      const details = { field: 'email', reason: 'invalid format' };
      const err = new ApiError(422, 'VALIDATION_ERROR', 'Invalid email', details);
      expect(err.details).toEqual(details);
    });

    it('works with various HTTP status codes', () => {
      expect(new ApiError(401, 'MISSING_AUTH', 'Unauthorized').statusCode).toBe(401);
      expect(new ApiError(403, 'ENTRY_ACCESS_DENIED', 'Forbidden').statusCode).toBe(403);
      expect(new ApiError(404, 'NOT_FOUND', 'Not found').statusCode).toBe(404);
      expect(new ApiError(409, 'ID_CONFLICT', 'Conflict').statusCode).toBe(409);
      expect(new ApiError(410, 'ENTRY_DELETED', 'Gone').statusCode).toBe(410);
      expect(new ApiError(500, 'INTERNAL_ERROR', 'Server error').statusCode).toBe(500);
    });

    it('is throwable and catchable', () => {
      expect(() => {
        throw new ApiError(400, 'VALIDATION_ERROR', 'test');
      }).toThrow(ApiError);
    });

    it('has a proper stack trace', () => {
      const err = new ApiError(400, 'VALIDATION_ERROR', 'stack test');
      expect(err.stack).toBeDefined();
      expect(err.stack).toContain('stack test');
    });
  });

  // ── sendError ──

  describe('sendError', () => {
    function mockReply() {
      let capturedStatus = 0;
      let capturedBody: unknown = null;
      const reply = {
        code(status: number) {
          capturedStatus = status;
          return reply;
        },
        send(body: unknown) {
          capturedBody = body;
          return reply;
        },
        getStatus: () => capturedStatus,
        getBody: () => capturedBody,
      };
      return reply;
    }

    it('sends error with correct status code and structure', () => {
      const reply = mockReply();
      const err = new ApiError(400, 'VALIDATION_ERROR', 'Bad input');
      sendError(reply as any, err);

      expect(reply.getStatus()).toBe(400);
      const body = reply.getBody() as any;
      expect(body.error.code).toBe('VALIDATION_ERROR');
      expect(body.error.message).toBe('Bad input');
      expect(body.error.details).toEqual({});
    });

    it('exposes only safe detail keys (field, reason, expected, actual)', () => {
      const reply = mockReply();
      const err = new ApiError(400, 'VALIDATION_ERROR', 'Invalid', {
        field: 'email',
        reason: 'format',
        expected: 'string',
        actual: 'number',
        internalSecret: 'should-be-filtered',
        stackTrace: 'should-be-filtered',
        sqlQuery: 'SELECT * FROM users',
      });
      sendError(reply as any, err);

      const body = reply.getBody() as any;
      expect(body.error.details.field).toBe('email');
      expect(body.error.details.reason).toBe('format');
      expect(body.error.details.expected).toBe('string');
      expect(body.error.details.actual).toBe('number');
      // These should NOT be in the response
      expect(body.error.details.internalSecret).toBeUndefined();
      expect(body.error.details.stackTrace).toBeUndefined();
      expect(body.error.details.sqlQuery).toBeUndefined();
    });

    it('returns empty details when error has no details', () => {
      const reply = mockReply();
      const err = new ApiError(404, 'NOT_FOUND', 'Not found');
      sendError(reply as any, err);

      const body = reply.getBody() as any;
      expect(body.error.details).toEqual({});
    });

    it('returns empty details when details has no safe keys', () => {
      const reply = mockReply();
      const err = new ApiError(500, 'INTERNAL_ERROR', 'Oops', {
        secret: 'password123',
        debug: 'internal info',
      });
      sendError(reply as any, err);

      const body = reply.getBody() as any;
      expect(body.error.details).toEqual({});
    });

    it('does not include stack trace in response', () => {
      const reply = mockReply();
      const err = new ApiError(500, 'INTERNAL_ERROR', 'Server error');
      sendError(reply as any, err);

      const body = reply.getBody() as any;
      expect(body.error.stack).toBeUndefined();
      expect(body.stack).toBeUndefined();
    });
  });
});

import { isPrismaError, withPrismaErrors } from '../src/errors.js';
import { ErrorCodes } from '../src/errorCodes.js';

describe('isPrismaError', () => {
  it('returns true for matching Prisma error code', () => {
    const err = { code: 'P2002', message: 'Unique constraint failed' };
    expect(isPrismaError(err, 'P2002')).toBe(true);
  });

  it('returns false for non-matching code', () => {
    const err = { code: 'P2002', message: 'Unique constraint failed' };
    expect(isPrismaError(err, 'P2025')).toBe(false);
  });

  it('returns false for null', () => {
    expect(isPrismaError(null, 'P2002')).toBe(false);
  });

  it('returns false for non-object', () => {
    expect(isPrismaError('string', 'P2002')).toBe(false);
    expect(isPrismaError(42, 'P2002')).toBe(false);
    expect(isPrismaError(undefined, 'P2002')).toBe(false);
  });

  it('returns false for object without code property', () => {
    expect(isPrismaError({ message: 'error' }, 'P2002')).toBe(false);
  });
});

describe('withPrismaErrors', () => {
  it('returns the result on success', async () => {
    const result = await withPrismaErrors(() => Promise.resolve({ id: '1' }));
    expect(result).toEqual({ id: '1' });
  });

  it('maps P2002 to 409 ID_CONFLICT', async () => {
    const operation = () => Promise.reject({ code: 'P2002' });
    await expect(withPrismaErrors(operation)).rejects.toMatchObject({
      statusCode: 409,
      code: ErrorCodes.ID_CONFLICT,
    });
  });

  it('maps P2002 with custom conflict message', async () => {
    const operation = () => Promise.reject({ code: 'P2002' });
    await expect(
      withPrismaErrors(operation, { conflictMessage: 'Duplicate entry' })
    ).rejects.toMatchObject({
      statusCode: 409,
      code: ErrorCodes.ID_CONFLICT,
      message: 'Duplicate entry',
    });
  });

  it('maps P2025 to 404 NOT_FOUND', async () => {
    const operation = () => Promise.reject({ code: 'P2025' });
    await expect(withPrismaErrors(operation)).rejects.toMatchObject({
      statusCode: 404,
      code: ErrorCodes.NOT_FOUND,
    });
  });

  it('maps P2025 with custom code and message', async () => {
    const operation = () => Promise.reject({ code: 'P2025' });
    await expect(
      withPrismaErrors(operation, {
        notFoundCode: ErrorCodes.ENTRY_NOT_FOUND,
        notFoundMessage: 'Entry not found',
      })
    ).rejects.toMatchObject({
      statusCode: 404,
      code: ErrorCodes.ENTRY_NOT_FOUND,
      message: 'Entry not found',
    });
  });

  it('re-throws non-Prisma errors', async () => {
    const originalError = new Error('DB connection failed');
    const operation = () => Promise.reject(originalError);
    await expect(withPrismaErrors(operation)).rejects.toBe(originalError);
  });

  it('re-throws unknown Prisma codes', async () => {
    const unknownErr = { code: 'P2003' };
    const operation = () => Promise.reject(unknownErr);
    await expect(withPrismaErrors(operation)).rejects.toBe(unknownErr);
  });
});
