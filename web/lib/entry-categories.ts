import { type Category, getClient } from "./dmoz-client.ts";

const ENTRY_LIMIT = 100;

export interface DirectoryEntry {
  root: Category | null;
  categories: Category[];
}

// DMOZ data has exactly one root (Top); the useful entry points are Top's
// children, so a singleton root set is drilled one level.
export async function loadEntryCategories(
  client: ReturnType<typeof getClient>,
): Promise<DirectoryEntry> {
  const roots = await client.listRootCategories(0, ENTRY_LIMIT);
  if (roots.length !== 1) return { root: null, categories: roots };

  const root = roots[0];
  try {
    const children = await client.listChildren(root.id, 0, ENTRY_LIMIT);
    if (children.length > 0) return { root, categories: children };
  } catch (e) {
    console.error("loadEntryCategories: listChildren failed:", e);
  }
  return { root, categories: roots };
}
