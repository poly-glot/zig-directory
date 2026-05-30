import { define } from "../../../utils.ts";
import { type Category, getClient } from "../../../lib/dmoz-client.ts";
import { loadAncestorMap } from "../../search/_lib/ancestors.ts";

/** Walk parent_id chain leaf→root using a pre-built ancestor map.
 * Returns names from root→…→leaf. */
function buildBreadcrumb(
  parentId: number,
  ancestors: Map<number, Category>,
): string[] {
  const chain: string[] = [];
  let id = parentId;
  let depth = 0;
  while (id !== 0 && depth < 16) {
    const cat = ancestors.get(id);
    if (!cat) break;
    chain.push(cat.name);
    id = cat.parentId;
    depth++;
  }
  return chain.reverse();
}

export const handler = define.handlers({
  async GET(ctx) {
    const q = ctx.url.searchParams.get("q")?.trim() ?? "";
    if (q.length < 2) return Response.json({ categories: [] });
    try {
      const client = getClient();
      const { categories } = await client.search(q, { limit: 20 });

      // One batched BFS per chain level instead of one getCategory per
      // ancestor per hit (was 60-100+ sequential RTTs for a 20-result
      // search with chain depth 3-5).
      const ancestors = await loadAncestorMap(
        client,
        categories.map((c) => c.parentId).filter((id) => id > 0),
        categories,
      );
      const enriched = categories.map((c) => ({
        id: c.id,
        name: c.name,
        slug: c.slug,
        parentId: c.parentId,
        // Render-ready: "Top / Arts / Music" (root → … → parent).
        breadcrumb: buildBreadcrumb(c.parentId, ancestors).join(" / "),
      }));
      return Response.json({ categories: enriched });
    } catch (e) {
      console.error("category-search failed:", e);
      return Response.json({ categories: [], error: String(e) }, {
        status: 500,
      });
    }
  },
});
