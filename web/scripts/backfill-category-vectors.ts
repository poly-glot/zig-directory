import {
  type Category,
  type CategoryVectorWrite,
  getClient,
  MAX_VECTORS_PER_WRITE,
} from "../lib/dmoz-client.ts";
import {
  categoryDocumentText,
  EMBEDDING_MODEL,
  embedText,
} from "../lib/embedder.ts";

const PAGE = 100;
const PROGRESS_EVERY = 2_000;

const client = getClient();
const counts = new Map<string, number>();
const started = performance.now();
let visited = 0;

async function* children(parentId: number): AsyncGenerator<Category> {
  for (let offset = 0;; offset += PAGE) {
    const page = parentId === 0
      ? await client.listRootCategories(offset, PAGE)
      : await client.listChildren(parentId, offset, PAGE);
    yield* page;
    if (page.length < PAGE) return;
  }
}

async function* walk(
  parentId: number,
  names: readonly string[],
): AsyncGenerator<{ category: Category; names: string[] }> {
  for await (const category of children(parentId)) {
    const path = [...names, category.name.replaceAll("_", " ")];
    yield { category, names: path };
    yield* walk(category.id, path);
  }
}

async function flush(writes: CategoryVectorWrite[]): Promise<void> {
  for (
    const { code } of await client.putCategoryVectors(EMBEDDING_MODEL, writes)
  ) {
    counts.set(code, (counts.get(code) ?? 0) + 1);
  }
  writes.length = 0;
}

const writes: CategoryVectorWrite[] = [];
for await (const { category, names } of walk(0, [])) {
  if (category.parentId === 0) continue;
  writes.push({
    categoryId: category.id,
    vector: await embedText(categoryDocumentText(names.slice(1))),
  });
  if (writes.length === MAX_VECTORS_PER_WRITE) await flush(writes);
  if (++visited % PROGRESS_EVERY === 0) {
    console.log(JSON.stringify({ visited, ...Object.fromEntries(counts) }));
  }
}
if (writes.length > 0) await flush(writes);

console.log(JSON.stringify({
  seconds: Math.round((performance.now() - started) / 1000),
  visited,
  results: Object.fromEntries(counts),
}));
Deno.exit(0);
