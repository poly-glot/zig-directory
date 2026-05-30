import { type Category, getClient } from "../../../lib/dmoz-client.ts";

/** Hard cap on parent-chain walks. Real DMOZ depth stays well under
 * this; the bound just protects against a corrupted parentId cycle. */
const MAX_DEPTH = 16;

/**
 * Build a `categoryId → Category` map covering every category referenced
 * by `directIds` and every ancestor up to the root. Performs one batched
 * RPC per BFS level (depth × RTT, not N × RTT).
 *
 * Missing or stale ids are silently skipped — the caller falls back to
 * the unprefixed category name when a path can't be assembled.
 *
 * `seed` lets the caller pre-populate the map (e.g. with the categories
 * already returned by the search response) so they don't need a second
 * fetch round-trip just to confirm what's already in hand.
 */
export async function loadAncestorMap(
  client: ReturnType<typeof getClient>,
  directIds: Iterable<number>,
  seed: Iterable<Category> = [],
): Promise<Map<number, Category>> {
  const map = new Map<number, Category>();
  for (const c of seed) map.set(c.id, c);

  let frontier = new Set<number>();
  for (const id of directIds) if (id > 0 && !map.has(id)) frontier.add(id);
  for (const c of seed) {
    if (c.parentId > 0 && !map.has(c.parentId)) frontier.add(c.parentId);
  }

  for (let depth = 0; depth < MAX_DEPTH && frontier.size > 0; depth++) {
    const ids = [...frontier];
    const cats = await client.getCategoriesByIds(ids);
    const next = new Set<number>();
    for (const c of cats) {
      map.set(c.id, c);
      if (c.parentId > 0 && !map.has(c.parentId)) next.add(c.parentId);
    }
    frontier = next;
  }
  return map;
}
