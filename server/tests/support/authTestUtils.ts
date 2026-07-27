import type { User } from '@prisma/client';

export function makeUser(overrides?: Partial<User>): User {
  return {
    id: 'user-1',
    displayName: 'Test User',
    globalRole: 'student',
    createdAt: new Date(),
    updatedAt: new Date(),
    ...overrides,
  } as User;
}
