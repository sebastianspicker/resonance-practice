/** Shared bounded page envelope; authorization and cursor scope remain with each feature. */
import { requireNumber } from './input.js';

export const DEFAULT_PAGE_SIZE = 50;
export const MAX_PAGE_SIZE = 200;

export function parsePageLimit(raw: string | undefined): number {
  return raw === undefined
    ? DEFAULT_PAGE_SIZE
    : Math.min(requireNumber(Number(raw), 'limit', { integer: true, min: 1 }), MAX_PAGE_SIZE);
}

export function cursorPage<T extends { id: string }>(rows: T[], limit: number) {
  const hasMore = rows.length > limit;
  const items = hasMore ? rows.slice(0, limit) : rows;
  return { items, nextCursor: hasMore ? (items.at(-1)?.id ?? null) : null };
}
