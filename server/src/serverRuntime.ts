/** Fastify runtime assembly kept separate from the public composition entry point. */
import type { S3Client } from '@aws-sdk/client-s3';
import cors from '@fastify/cors';
import helmet from '@fastify/helmet';
import rateLimit from '@fastify/rate-limit';
import type { PrismaClient } from '@prisma/client';
import Fastify from 'fastify';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { verifyAccessToken } from './auth.js';
import { config, limits } from './config.js';
import { ErrorCodes } from './errorCodes.js';
import { ApiError, sendError } from './errors.js';
import { registerArtifactRoutes } from './routes/artifacts.js';
import { registerAuthRoutes } from './routes/auth.js';
import { registerCourseRoutes } from './routes/courses.js';
import { registerEntryRoutes } from './routes/entries.js';
import { registerFeedbackRoutes } from './routes/feedback.js';
import { registerV1Routes } from './routes/v1.js';
import { withDeadline } from './services/deadline.js';
import { checkBucketAvailable } from './storage.js';

const BODY_METHODS = new Set(['POST', 'PUT', 'PATCH']);

type FastifyErrorShape = { statusCode?: number; code?: string; message?: string };

function errorResponse(status: number, code: string, message: string) {
  return {
    status,
    body: { error: { code, message, details: {} } },
  };
}

function contentTypeErrorResponse(code: string) {
  if (code === 'FST_ERR_CTP_INVALID_JSON_BODY') {
    return errorResponse(400, ErrorCodes.VALIDATION_ERROR, 'Invalid JSON in request body');
  }
  if (code === 'FST_ERR_CTP_BODY_TOO_LARGE') {
    return errorResponse(413, ErrorCodes.VALIDATION_ERROR, 'Request body is too large');
  }
  return errorResponse(415, ErrorCodes.VALIDATION_ERROR, 'Unsupported content type');
}

function classifyFastifyError(error: FastifyErrorShape) {
  if (error.statusCode === 429) {
    return errorResponse(
      429,
      ErrorCodes.RATE_LIMITED,
      'Too many requests. Please try again later.'
    );
  }
  if (typeof error.code === 'string' && error.code.startsWith('FST_ERR_CTP')) {
    return contentTypeErrorResponse(error.code);
  }

  const status = error.statusCode ?? 500;
  return errorResponse(
    status,
    status >= 500 ? ErrorCodes.INTERNAL_ERROR : ErrorCodes.VALIDATION_ERROR,
    status >= 500 ? 'Unexpected error' : error.message || 'Bad request'
  );
}

export function createApiApp() {
  return Fastify({
    logger: {
      redact: [
        'req.headers.authorization',
        'req.body.password',
        'req.body.refreshToken',
        'req.body.accessToken',
        'req.body.code',
      ],
    },
    requestIdHeader: 'x-request-id',
    requestIdLogLabel: 'requestId',
    bodyLimit: limits.bodyLimitBytes,
  });
}

/** Share one database and storage probe across concurrent readiness callers. */
export function createDependencyCheck(prisma: PrismaClient, s3: S3Client): () => Promise<void> {
  let activeCheck: Promise<void> | null = null;

  return function checkDependencies(): Promise<void> {
    if (activeCheck) return activeCheck;
    const check = (async () => {
      const results = await Promise.allSettled([
        prisma.$queryRaw`SELECT 1`,
        checkBucketAvailable(s3),
      ]);
      const failure = results.find(
        (result): result is PromiseRejectedResult => result.status === 'rejected'
      );
      if (failure) throw failure.reason;
    })();
    activeCheck = check;
    void check.then(
      () => {
        if (activeCheck === check) activeCheck = null;
      },
      () => {
        if (activeCheck === check) activeCheck = null;
      }
    );
    return check;
  };
}

function isLoopback(ip: string | undefined) {
  return ip === '127.0.0.1' || ip === '::1' || ip === '::ffff:127.0.0.1';
}

function registerRateLimit(app: FastifyInstance) {
  app.register(rateLimit, {
    max: 100,
    timeWindow: '1 minute',
    allowList: (request, _key) => {
      if (request.url === '/health' || request.url === '/ready') return true;
      return config.authMode === 'dev' && isLoopback(request.ip);
    },
  });
}

function registerSecurityHeaders(app: FastifyInstance) {
  app.register(helmet, {
    contentSecurityPolicy: {
      directives: { defaultSrc: ["'none'"], frameAncestors: ["'none'"] },
    },
    xContentTypeOptions: true,
    frameguard: { action: 'deny' },
    strictTransportSecurity:
      config.authMode === 'prod' ? { maxAge: 31_536_000, includeSubDomains: true } : false,
    referrerPolicy: { policy: 'no-referrer' },
    dnsPrefetchControl: { allow: false },
    permittedCrossDomainPolicies: { permittedPolicies: 'none' },
  });
}

function registerRequestHooks(app: FastifyInstance) {
  app.addHook('onSend', async (request, reply) => {
    reply.removeHeader('x-powered-by');
    reply.header('x-request-id', request.id);
  });

  app.addHook('preHandler', async (request) => {
    if (!BODY_METHODS.has(request.method)) return;
    const contentType = request.headers['content-type'];
    if (contentType && !contentType.startsWith('application/json')) {
      throw new ApiError(415, ErrorCodes.VALIDATION_ERROR, 'Content-Type must be application/json');
    }
  });
}

function registerErrorHandlers(app: FastifyInstance) {
  app.setErrorHandler((error, request, reply) => {
    if (error instanceof ApiError) {
      return sendError(reply, error, request.id);
    }

    const errorResult = classifyFastifyError(error as FastifyErrorShape);
    if (errorResult.status >= 500) request.log.error(error);
    else request.log.warn(error);
    return reply.code(errorResult.status).send({
      error: { ...errorResult.body.error, requestId: request.id },
    });
  });

  app.setNotFoundHandler((request, reply) => {
    sendError(reply, new ApiError(404, ErrorCodes.NOT_FOUND, 'Route not found'), request.id);
  });
}

export function registerTransport(app: FastifyInstance) {
  registerRateLimit(app);
  const corsOptions =
    config.corsOrigins.length > 0 ? { origin: config.corsOrigins } : { origin: false };
  app.register(cors, corsOptions);
  registerSecurityHeaders(app);
  registerRequestHooks(app);
  registerErrorHandlers(app);
}

async function requireAuth(request: FastifyRequest) {
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

export function registerStatusRoutes(app: FastifyInstance, checkDependencies: () => Promise<void>) {
  app.get('/health', async () => ({ status: 'ok' }));
  app.get('/ready', async (request, reply) => {
    try {
      await withDeadline(
        checkDependencies,
        config.dependencyTimeoutMs,
        'Dependency readiness check'
      );
      return { status: 'ready' };
    } catch (error) {
      request.log.warn({ err: error }, 'Readiness dependency check failed');
      return reply.status(503).send({ status: 'unavailable' });
    }
  });
}

export function registerResourceRoutes(app: FastifyInstance, prisma: PrismaClient, s3: S3Client) {
  registerAuthRoutes(app, prisma, requireAuth);
  registerCourseRoutes(app, prisma, requireAuth);
  registerEntryRoutes(app, prisma, requireAuth);
  registerArtifactRoutes(app, prisma, s3, requireAuth);
  registerFeedbackRoutes(app, prisma, requireAuth);
  registerV1Routes(app, prisma, s3, requireAuth);
}
