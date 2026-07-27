/** Fastify composition root for middleware, routes, and readiness coordination. */
import type { S3Client } from '@aws-sdk/client-s3';
import cors from '@fastify/cors';
import helmet from '@fastify/helmet';
import rateLimit from '@fastify/rate-limit';
import type { PrismaClient } from '@prisma/client';
import Fastify from 'fastify';
import type { FastifyRequest } from 'fastify';
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

/** HTTP methods that carry a request body and must send application/json. */
const BODY_METHODS = new Set(['POST', 'PUT', 'PATCH']);

type FastifyErrorShape = { statusCode?: number; code?: string; message?: string };

function errorResponse(status: number, code: string, message: string) {
  return {
    status,
    body: {
      error: {
        code,
        message,
        details: {},
      },
    },
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

/**
 * Compose the API around injected database and storage clients so production
 * lifecycle code and tests exercise the same middleware and route graph.
 */
export function buildServer(prisma: PrismaClient, s3: S3Client) {
  const app = Fastify({
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
  let activeReadinessCheck: Promise<void> | null = null;

  /** Share one dependency probe across concurrent readiness callers. */
  function checkDependencies(): Promise<void> {
    if (activeReadinessCheck) return activeReadinessCheck;
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
    activeReadinessCheck = check;
    void check.then(
      () => {
        if (activeReadinessCheck === check) activeReadinessCheck = null;
      },
      () => {
        if (activeReadinessCheck === check) activeReadinessCheck = null;
      }
    );
    return check;
  }

  // --- Rate limiting --------------------------------------------------------
  const isLoopback = (ip: string | undefined) =>
    ip === '127.0.0.1' || ip === '::1' || ip === '::ffff:127.0.0.1';

  app.register(rateLimit, {
    max: 100,
    timeWindow: '1 minute',
    allowList: (req, _key) => {
      // Health endpoint should never be throttled (uptime probes, load balancers)
      if (req.url === '/health' || req.url === '/ready') return true;
      // In dev mode, exempt localhost to avoid throttling dev/test traffic
      if (config.authMode === 'dev' && isLoopback(req.ip)) return true;
      return false;
    },
  });

  // --- CORS -----------------------------------------------------------------
  const corsOptions =
    config.corsOrigins.length > 0 ? { origin: config.corsOrigins } : { origin: false };
  app.register(cors, corsOptions);

  // --- Helmet (security headers) --------------------------------------------
  app.register(helmet, {
    // API-only CSP: deny everything except JSON responses
    contentSecurityPolicy: {
      directives: {
        defaultSrc: ["'none'"],
        frameAncestors: ["'none'"],
      },
    },
    // Prevent MIME-type sniffing
    xContentTypeOptions: true,
    // Prevent framing
    frameguard: { action: 'deny' },
    // HSTS: enable in production (1 year, includeSubDomains)
    strictTransportSecurity:
      config.authMode === 'prod' ? { maxAge: 31_536_000, includeSubDomains: true } : false,
    // Referrer leak prevention
    referrerPolicy: { policy: 'no-referrer' },
    // This is not an HTML app, so disable DNS prefetch, download guard, and permitted cross-domain policies.
    dnsPrefetchControl: { allow: false },
    permittedCrossDomainPolicies: { permittedPolicies: 'none' },
  });

  // --- Remove server identity header & add request-id -----------------------
  app.addHook('onSend', async (request, reply) => {
    reply.removeHeader('x-powered-by');
    reply.header('x-request-id', request.id);
  });

  // --- Content-Type enforcement for request bodies --------------------------
  app.addHook('preHandler', async (request) => {
    if (BODY_METHODS.has(request.method)) {
      const ct = request.headers['content-type'];
      // Allow empty bodies (some POSTs like /entries/:id/submit have no body)
      // but otherwise require JSON.
      if (ct && !ct.startsWith('application/json')) {
        throw new ApiError(
          415,
          ErrorCodes.VALIDATION_ERROR,
          'Content-Type must be application/json'
        );
      }
    }
  });

  // --- Error handler --------------------------------------------------------
  app.setErrorHandler((error, request, reply) => {
    if (error instanceof ApiError) {
      return sendError(reply, error, request.id);
    }

    const fastifyErr = error as FastifyErrorShape;
    const errorResult = classifyFastifyError(fastifyErr);
    // Log only unexpected (5xx) errors at error level; 4xx are client mistakes
    if (errorResult.status >= 500) {
      request.log.error(error);
    } else {
      request.log.warn(error);
    }
    return reply.code(errorResult.status).send({
      error: {
        ...errorResult.body.error,
        requestId: request.id,
      },
    });
  });

  app.setNotFoundHandler((request, reply) => {
    sendError(reply, new ApiError(404, ErrorCodes.NOT_FOUND, 'Route not found'), request.id);
  });

  // --- Auth hook ------------------------------------------------------------
  const requireAuth = async (request: FastifyRequest) => {
    const header = request.headers.authorization;
    if (!header || !header.startsWith('Bearer ')) {
      throw new ApiError(401, ErrorCodes.MISSING_AUTH, 'Missing or invalid Authorization header');
    }
    const token = header.slice(7);
    const payload = verifyAccessToken(token);
    const userId = payload.sub as string | undefined;
    const role = payload.role as 'student' | 'teacher' | undefined;
    if (!userId || !role) {
      throw new ApiError(401, ErrorCodes.INVALID_TOKEN, 'Invalid token payload');
    }
    request.user = { id: userId, role };
  };

  // --- Routes ---------------------------------------------------------------
  app.get('/health', async () => ({ status: 'ok' }));
  app.get('/ready', async (request, reply) => {
    try {
      await withDeadline(
        () => checkDependencies(),
        config.dependencyTimeoutMs,
        'Dependency readiness check'
      );
      return { status: 'ready' };
    } catch (error) {
      request.log.warn({ err: error }, 'Readiness dependency check failed');
      return reply.status(503).send({ status: 'unavailable' });
    }
  });

  registerAuthRoutes(app, prisma, requireAuth);
  registerCourseRoutes(app, prisma, requireAuth);
  registerEntryRoutes(app, prisma, requireAuth);
  registerArtifactRoutes(app, prisma, s3, requireAuth);
  registerFeedbackRoutes(app, prisma, requireAuth);
  registerV1Routes(app, prisma, s3, requireAuth);

  return app;
}
