/**
 * One-shot migration: collapse the duplicate "Top" root (id 1) into
 * the canonical Top (id 3). Moves any children of id 1 over to id 3,
 * then deletes id 1. Run manually once per environment:
 *
 *   cd web && DMOZDB_HOST=127.0.0.1 deno run -A scripts/migrate-canonical-root.ts
 *
 * Prints before/after counts. Exits non-zero on any unexpected state.
 */
import { getClient } from "../lib/dmoz-client.ts";
import { CANONICAL_ROOT_ID } from "../lib/admin-constants.ts";

const c = getClient();

const before = await c.listRootCategories(0, 50);
console.log(
  "Before:",
  before.map((r) => ({
    id: r.id,
    name: r.name,
    children: r.childCount,
    subtreeLinks: r.linkCountSubtree,
  })),
);

const dup = before.find((r) => r.id !== CANONICAL_ROOT_ID && r.name === "Top");
if (!dup) {
  console.log("Nothing to migrate (no duplicate Top root).");
  Deno.exit(0);
}

const canonical = before.find((r) => r.id === CANONICAL_ROOT_ID);
if (!canonical) {
  console.error("FATAL: canonical root", CANONICAL_ROOT_ID, "not found.");
  Deno.exit(1);
}

console.log(`Migrating children of #${dup.id} → #${CANONICAL_ROOT_ID}`);
const children = await c.listChildren(dup.id, 0, 500);
for (const child of children) {
  console.log("  move", child.id, child.name);
  await c.moveCategory(child.id, CANONICAL_ROOT_ID);
}

console.log(`Deleting empty root #${dup.id}`);
await c.deleteCategory(dup.id);

const after = await c.listRootCategories(0, 50);
console.log(
  "After:",
  after.map((r) => ({ id: r.id, name: r.name, children: r.childCount })),
);

if (after.length !== 1 || after[0].id !== CANONICAL_ROOT_ID) {
  console.error(
    "FATAL: post-migration root list is not exactly [CANONICAL_ROOT_ID].",
  );
  Deno.exit(1);
}
console.log("OK.");
