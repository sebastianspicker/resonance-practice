/** Shared bounded page envelope; authorization and cursor scope remain with each feature. */
import { requireNumber } from './input.js';
import { ErrorCodes } from './errorCodes.js';
import { ApiError } from './errors.js';

export const DEFAULT_PAGE_SIZE = 50;
export const MAX_PAGE_SIZE = 200;
const MAX_SERIALIZED_PAGE_BYTES = 7 * 1024 * 1024;
const PAGE_PREFIX_BYTES = Buffer.byteLength('{"items":[', 'utf8');
const PAGE_CURSOR_PREFIX_BYTES = Buffer.byteLength('],"nextCursor":', 'utf8');
const PAGE_SUFFIX_BYTES = Buffer.byteLength('}', 'utf8');

// Nested collections make entry and feedback rows much larger than ordinary list rows.
export const MAX_ENTRY_ROWS_PER_FETCH = 2;
export const MAX_NESTED_ROWS_PER_FETCH = 20;

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

/**
 * Keep a page below the shared transport budget without truncating an item or
 * skipping it on the next cursor request. Callers must pass transport DTOs,
 * not raw records with private fields.
 */
export function fitPageToByteBudget<T extends { id: string }>(
  page: { items: T[]; nextCursor: string | null },
  maximumBytes = MAX_SERIALIZED_PAGE_BYTES
) {
  const items: T[] = [];
  const itemByteLengths: number[] = [];
  let itemsByteLength = 0;

  for (const item of page.items) {
    const itemByteLength = Buffer.byteLength(JSON.stringify(item), 'utf8');
    if (
      pageByteLength(items.length + 1, itemsByteLength + itemByteLength, item.id) > maximumBytes
    ) {
      const lastIncluded = items.at(-1);
      if (!lastIncluded) {
        throw new ApiError(
          500,
          ErrorCodes.INTERNAL_ERROR,
          'A response item exceeds the transport size limit'
        );
      }
      return { items, nextCursor: lastIncluded.id };
    }
    items.push(item);
    itemByteLengths.push(itemByteLength);
    itemsByteLength += itemByteLength;
  }

  if (pageByteLength(items.length, itemsByteLength, page.nextCursor) > maximumBytes) {
    while (true) {
      const deferred = items.pop();
      itemsByteLength -= itemByteLengths.pop() ?? 0;
      const lastIncluded = items.at(-1);
      if (!deferred || !lastIncluded) {
        throw new ApiError(
          500,
          ErrorCodes.INTERNAL_ERROR,
          'A response item exceeds the transport size limit'
        );
      }
      if (pageByteLength(items.length, itemsByteLength, lastIncluded.id) <= maximumBytes) {
        return { items, nextCursor: lastIncluded.id };
      }
    }
  }
  return { items, nextCursor: page.nextCursor };
}

function pageByteLength(itemCount: number, itemsByteLength: number, nextCursor: string | null) {
  return (
    PAGE_PREFIX_BYTES +
    itemsByteLength +
    Math.max(0, itemCount - 1) +
    PAGE_CURSOR_PREFIX_BYTES +
    Buffer.byteLength(JSON.stringify(nextCursor), 'utf8') +
    PAGE_SUFFIX_BYTES
  );
}

/**
 * Fetch nested rows in small batches and stop at either the requested item
 * count or the serialized response budget. The returned cursor always points
 * at the last included item, so a deferred row is never skipped.
 */
export async function collectPageWithinByteBudget<
  T extends { id: string },
  WireItem extends { id: string },
>(
  cursor: string | undefined,
  limit: number,
  batchSize: number,
  fetchRows: (cursor: string | undefined, take: number) => Promise<T[]>,
  toWireItem: (row: T) => WireItem
) {
  const items: T[] = [];
  let wireItemsByteLength = 0;
  let batchCursor = cursor;

  while (true) {
    const take = Math.min(batchSize, limit + 1 - items.length);
    const rows = await fetchRows(batchCursor, take);
    if (rows.length === 0) return { items, nextCursor: null };

    for (const row of rows) {
      if (items.length === limit) {
        return { items, nextCursor: items.at(-1)?.id ?? null };
      }
      const wireItem = toWireItem(row);
      const wireItemByteLength = Buffer.byteLength(JSON.stringify(wireItem), 'utf8');
      if (
        pageByteLength(items.length + 1, wireItemsByteLength + wireItemByteLength, wireItem.id) >
        MAX_SERIALIZED_PAGE_BYTES
      ) {
        if (items.length === 0) {
          throw new ApiError(
            500,
            ErrorCodes.INTERNAL_ERROR,
            'A response item exceeds the transport size limit'
          );
        }
        return { items, nextCursor: items.at(-1)?.id ?? null };
      }
      items.push(row);
      wireItemsByteLength += wireItemByteLength;
    }

    if (rows.length < take) return { items, nextCursor: null };
    batchCursor = rows.at(-1)?.id;
  }
}
