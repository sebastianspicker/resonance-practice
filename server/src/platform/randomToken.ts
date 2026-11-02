import { randomBytes } from 'node:crypto';

/** URL-safe random token carrying `bytes` bytes of entropy. */
export function randomToken(bytes: number): string {
  return randomBytes(bytes).toString('base64url');
}
