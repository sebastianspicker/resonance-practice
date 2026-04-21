import { describe, expect, it } from 'vitest';
import { validateDevCallbackUrl } from '../src/config.js';

/**
 * Tests for config.ts validation branches:
 * - Invalid DEV_LOGIN_CALLBACK_URL (bad scheme) via the exported function
 *
 * The top-level config validations (JWT_SECRET length, PORT, TTL values)
 * run at import time and are tested via a separate subprocess-based test
 * (config-subprocess.test.ts) since ESM module caching prevents re-import
 * with different env vars within the same process.
 */

describe('config validation', () => {
  describe('validateDevCallbackUrl', () => {
    it('accepts resonance:// scheme', () => {
      expect(validateDevCallbackUrl('resonance://auth-callback')).toBe('resonance://auth-callback');
    });

    it('accepts http://localhost scheme', () => {
      expect(validateDevCallbackUrl('http://localhost:3000/callback')).toBe(
        'http://localhost:3000/callback'
      );
    });

    it('rejects https:// scheme', () => {
      expect(() => validateDevCallbackUrl('https://example.com/callback')).toThrow(
        'DEV_LOGIN_CALLBACK_URL must start with "resonance://" or "http://localhost"'
      );
    });

    it('rejects http:// non-localhost scheme', () => {
      expect(() => validateDevCallbackUrl('http://evil.com/callback')).toThrow(
        'DEV_LOGIN_CALLBACK_URL must start with "resonance://" or "http://localhost"'
      );
    });

    it('rejects ftp:// scheme', () => {
      expect(() => validateDevCallbackUrl('ftp://server/file')).toThrow(
        'DEV_LOGIN_CALLBACK_URL must start with "resonance://" or "http://localhost"'
      );
    });

    it('rejects empty string', () => {
      expect(() => validateDevCallbackUrl('')).toThrow(
        'DEV_LOGIN_CALLBACK_URL must start with "resonance://" or "http://localhost"'
      );
    });

    it('rejects javascript: scheme', () => {
      expect(() => validateDevCallbackUrl('javascript:alert(1)')).toThrow(
        'DEV_LOGIN_CALLBACK_URL must start with "resonance://" or "http://localhost"'
      );
    });

    it('rejects data: URI scheme', () => {
      expect(() => validateDevCallbackUrl('data:text/html,<h1>hi</h1>')).toThrow(
        'DEV_LOGIN_CALLBACK_URL must start with "resonance://" or "http://localhost"'
      );
    });

    it('includes the offending URL in the error message', () => {
      const badUrl = 'https://attacker.com/steal';
      try {
        validateDevCallbackUrl(badUrl);
        expect.unreachable('should have thrown');
      } catch (e) {
        expect((e as Error).message).toContain(`Got: "${badUrl}"`);
      }
    });
  });
});
