/** Cursor-page shaping shared by list routes. */
export function toCursorPage<T extends { id: string }>(items: T[], limit: number) {
  const hasMore = items.length > limit;
  const pageItems = hasMore ? items.slice(0, limit) : items;
  const lastItem = pageItems[pageItems.length - 1];
  return { items: pageItems, nextCursor: hasMore && lastItem ? lastItem.id : null };
}
