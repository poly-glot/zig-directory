import { define } from "../../../utils.ts";
import { getClient } from "../../../lib/dmoz-client.ts";

export const handler = define.handlers({
  async GET(ctx) {
    const q = ctx.url.searchParams.get("q")?.trim() ?? "";
    if (q.length < 2) return Response.json({ categories: [] });
    try {
      const client = getClient();
      const { categories } = await client.search(q, { limit: 20 });

      const chains = await client.breadcrumbsByIds(
        categories.map((c) => c.parentId).filter((id) => id > 0),
      );
      const enriched = categories.map((c) => ({
        id: c.id,
        name: c.name,
        slug: c.slug,
        parentId: c.parentId,
        // Render-ready: "Top / Arts / Music" (root → … → parent).
        breadcrumb: (chains.get(c.parentId) ?? []).map((b) => b.name).join(
          " / ",
        ),
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
