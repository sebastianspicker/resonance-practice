import { describe, expect, it } from 'vitest';
import { ApiError } from '../src/errors.js';
import {
  requireField,
  requireString,
  requireEnum,
  requireStringArray,
  requireValidDate,
  requireNumber,
  requireClientId,
} from '../src/validation.js';

describe('validation helpers (unit)', () => {
  // ── requireField ──

  describe('requireField', () => {
    it('returns the value when present', () => {
      expect(requireField('hello', 'name')).toBe('hello');
      expect(requireField(0, 'count')).toBe(0);
      expect(requireField(false, 'flag')).toBe(false);
      expect(requireField('', 'empty')).toBe('');
    });

    it('throws on undefined', () => {
      expect(() => requireField(undefined, 'x')).toThrow(ApiError);
      try {
        requireField(undefined, 'x');
      } catch (e) {
        const err = e as ApiError;
        expect(err.statusCode).toBe(400);
        expect(err.code).toBe('VALIDATION_ERROR');
        expect(err.message).toContain('x');
      }
    });

    it('throws on null', () => {
      expect(() => requireField(null, 'y')).toThrow(ApiError);
    });
  });

  // ── requireString ──

  describe('requireString', () => {
    it('returns valid strings', () => {
      expect(requireString('abc', 'f')).toBe('abc');
      expect(requireString('', 'f')).toBe('');
    });

    it('throws for non-string types', () => {
      expect(() => requireString(123, 'f')).toThrow(ApiError);
      expect(() => requireString(true, 'f')).toThrow(ApiError);
      expect(() => requireString(null, 'f')).toThrow(ApiError);
      expect(() => requireString(undefined, 'f')).toThrow(ApiError);
      expect(() => requireString([], 'f')).toThrow(ApiError);
      expect(() => requireString({}, 'f')).toThrow(ApiError);
    });

    it('uses default max of 10000', () => {
      expect(requireString('a'.repeat(10000), 'f')).toHaveLength(10000);
      expect(() => requireString('a'.repeat(10001), 'f')).toThrow(ApiError);
    });

    it('respects custom max option', () => {
      expect(requireString('abc', 'f', { max: 5 })).toBe('abc');
      expect(() => requireString('abcdef', 'f', { max: 5 })).toThrow(ApiError);
    });

    it('error message includes field name', () => {
      try {
        requireString(42, 'myField');
      } catch (e) {
        expect((e as ApiError).message).toContain('myField');
      }
    });
  });

  // ── requireEnum ──

  describe('requireEnum', () => {
    const allowed = ['draft', 'submitted', 'reviewed'] as const;

    it('returns value when in allowed set', () => {
      expect(requireEnum('draft', 'status', allowed)).toBe('draft');
      expect(requireEnum('submitted', 'status', allowed)).toBe('submitted');
    });

    it('throws for value not in allowed set', () => {
      expect(() => requireEnum('deleted', 'status', allowed)).toThrow(ApiError);
    });

    it('throws for non-string values', () => {
      expect(() => requireEnum(123, 'status', allowed)).toThrow(ApiError);
    });
  });

  // ── requireStringArray ──

  describe('requireStringArray', () => {
    it('returns valid string arrays', () => {
      expect(requireStringArray(['a', 'b'], 'tags')).toEqual(['a', 'b']);
      expect(requireStringArray([], 'tags')).toEqual([]);
    });

    it('throws for non-array values', () => {
      expect(() => requireStringArray('not-array', 'tags')).toThrow(ApiError);
      expect(() => requireStringArray(null, 'tags')).toThrow(ApiError);
      expect(() => requireStringArray(123, 'tags')).toThrow(ApiError);
    });

    it('throws when array contains non-strings', () => {
      expect(() => requireStringArray(['a', 123], 'tags')).toThrow(ApiError);
      expect(() => requireStringArray([null], 'tags')).toThrow(ApiError);
      expect(() => requireStringArray([undefined], 'tags')).toThrow(ApiError);
    });

    it('uses default max of 100', () => {
      const arr = Array.from({ length: 100 }, (_, i) => `item-${i}`);
      expect(requireStringArray(arr, 'tags')).toHaveLength(100);
      arr.push('one-too-many');
      expect(() => requireStringArray(arr, 'tags')).toThrow(ApiError);
    });

    it('respects custom max option', () => {
      expect(requireStringArray(['a', 'b'], 'tags', { max: 3 })).toEqual(['a', 'b']);
      expect(() => requireStringArray(['a', 'b', 'c', 'd'], 'tags', { max: 3 })).toThrow(ApiError);
    });
  });

  // ── requireValidDate ──

  describe('requireValidDate', () => {
    it('accepts date-only ISO 8601 strings', () => {
      const d = requireValidDate('2025-03-21', 'date');
      expect(d).toBeInstanceOf(Date);
      expect(d.toISOString()).toContain('2025-03-21');
    });

    it('accepts full ISO 8601 with Z timezone', () => {
      const d = requireValidDate('2025-03-21T14:30:00Z', 'date');
      expect(d).toBeInstanceOf(Date);
    });

    it('accepts full ISO 8601 with milliseconds and Z', () => {
      const d = requireValidDate('2025-03-21T14:30:00.123Z', 'date');
      expect(d).toBeInstanceOf(Date);
    });

    it('accepts full ISO 8601 with positive offset', () => {
      const d = requireValidDate('2025-03-21T14:30:00+05:30', 'date');
      expect(d).toBeInstanceOf(Date);
    });

    it('accepts full ISO 8601 with negative offset', () => {
      const d = requireValidDate('2025-03-21T14:30:00-04:00', 'date');
      expect(d).toBeInstanceOf(Date);
    });

    it('rejects datetime without timezone', () => {
      expect(() => requireValidDate('2025-03-21T14:30:00', 'date')).toThrow(ApiError);
    });

    it('rejects datetime with milliseconds but no timezone', () => {
      expect(() => requireValidDate('2025-03-21T14:30:00.123', 'date')).toThrow(ApiError);
    });

    it('rejects non-ISO formats', () => {
      expect(() => requireValidDate('03/21/2025', 'date')).toThrow(ApiError);
      expect(() => requireValidDate('March 21 2025', 'date')).toThrow(ApiError);
      expect(() => requireValidDate('not-a-date', 'date')).toThrow(ApiError);
    });

    it('rejects impossible calendar dates instead of normalizing them', () => {
      expect(() => requireValidDate('2025-02-30', 'date')).toThrow(ApiError);
      expect(() => requireValidDate('2025-04-31', 'date')).toThrow(ApiError);
    });

    it('rejects invalid calendar dates that parse to NaN', () => {
      expect(() => requireValidDate('0000-00-00', 'date')).toThrow(ApiError);
    });

    it('coerces non-string values via String()', () => {
      // A number will be stringified and likely fail the regex
      expect(() => requireValidDate(12345, 'date')).toThrow(ApiError);
    });
  });

  // ── requireNumber ──

  describe('requireNumber', () => {
    it('returns valid numbers', () => {
      expect(requireNumber(42, 'n')).toBe(42);
      expect(requireNumber(0, 'n')).toBe(0);
      expect(requireNumber(-1, 'n')).toBe(-1);
      expect(requireNumber(3.14, 'n')).toBe(3.14);
    });

    it('throws for non-number types', () => {
      expect(() => requireNumber('42', 'n')).toThrow(ApiError);
      expect(() => requireNumber(null, 'n')).toThrow(ApiError);
      expect(() => requireNumber(undefined, 'n')).toThrow(ApiError);
      expect(() => requireNumber(true, 'n')).toThrow(ApiError);
    });

    it('throws for NaN', () => {
      expect(() => requireNumber(NaN, 'n')).toThrow(ApiError);
    });

    it('enforces integer constraint when requested', () => {
      expect(requireNumber(42, 'n', { integer: true })).toBe(42);
      expect(() => requireNumber(3.14, 'n', { integer: true })).toThrow(ApiError);
    });

    it('enforces min constraint', () => {
      expect(requireNumber(5, 'n', { min: 0 })).toBe(5);
      expect(requireNumber(0, 'n', { min: 0 })).toBe(0);
      expect(() => requireNumber(-1, 'n', { min: 0 })).toThrow(ApiError);
    });

    it('enforces max constraint', () => {
      expect(requireNumber(100, 'n', { max: 100 })).toBe(100);
      expect(() => requireNumber(101, 'n', { max: 100 })).toThrow(ApiError);
    });

    it('enforces both min and max constraints', () => {
      expect(requireNumber(50, 'n', { min: 0, max: 100 })).toBe(50);
      expect(() => requireNumber(-1, 'n', { min: 0, max: 100 })).toThrow(ApiError);
      expect(() => requireNumber(101, 'n', { min: 0, max: 100 })).toThrow(ApiError);
    });

    it('error includes field name for min violation', () => {
      try {
        requireNumber(-1, 'myNum', { min: 0 });
      } catch (e) {
        expect((e as ApiError).message).toContain('myNum');
        expect((e as ApiError).message).toContain('too small');
      }
    });

    it('error includes field name for max violation', () => {
      try {
        requireNumber(200, 'myNum', { max: 100 });
      } catch (e) {
        expect((e as ApiError).message).toContain('myNum');
        expect((e as ApiError).message).toContain('too large');
      }
    });
  });

  // ── requireClientId ──

  describe('requireClientId', () => {
    it('accepts valid alphanumeric IDs', () => {
      expect(requireClientId('abc123', 'id')).toBe('abc123');
      expect(requireClientId('ABC', 'id')).toBe('ABC');
    });

    it('accepts hyphens and underscores', () => {
      expect(requireClientId('entry_2025-03-21_abc', 'id')).toBe('entry_2025-03-21_abc');
    });

    it('accepts single character', () => {
      expect(requireClientId('a', 'id')).toBe('a');
    });

    it('accepts 128-character ID (boundary)', () => {
      const id = 'a'.repeat(128);
      expect(requireClientId(id, 'id')).toBe(id);
    });

    it('rejects 129-character ID', () => {
      expect(() => requireClientId('a'.repeat(129), 'id')).toThrow(ApiError);
    });

    it('rejects empty string', () => {
      expect(() => requireClientId('', 'id')).toThrow(ApiError);
    });

    it('rejects special characters', () => {
      expect(() => requireClientId('id with spaces', 'id')).toThrow(ApiError);
      expect(() => requireClientId('../path', 'id')).toThrow(ApiError);
      expect(() => requireClientId('id<script>', 'id')).toThrow(ApiError);
      expect(() => requireClientId('id;drop', 'id')).toThrow(ApiError);
    });

    it('rejects non-string input', () => {
      expect(() => requireClientId(123, 'id')).toThrow(ApiError);
      expect(() => requireClientId(null, 'id')).toThrow(ApiError);
    });
  });
});
