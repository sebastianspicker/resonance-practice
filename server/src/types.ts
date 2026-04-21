export type AuthUser = {
  id: string;
  role: 'student' | 'teacher';
};

declare module 'fastify' {
  interface FastifyRequest {
    user?: AuthUser;
  }
}
