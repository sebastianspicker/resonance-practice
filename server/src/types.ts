/** Shared Fastify request augmentation for authenticated application users. */
export type AuthUser = {
  id: string;
  role: 'student' | 'teacher';
};

declare module 'fastify' {
  interface FastifyRequest {
    user?: AuthUser;
  }
}
