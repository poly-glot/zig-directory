import { define } from "../../../utils.ts";
import { getClient } from "../../../lib/dmoz-client.ts";

// GET /admin/api/search?q=…&scope=links|categories|both&limit=N
// Debounced live search for AdminSearchBar. Admin-gated by routes/admin/_middleware.ts.
export const handler = define.handlers({
  async GET(ctx) {
    const q = ctx.url.searchParams.get("q")?.trim() ?? "";
    const scopeRaw = ctx.url.searchParams.get("scope");
    const limit = Math.min(
      50,
      Math.max(1, Number(ctx.url.searchParams.get("limit") ?? "20") || 20),
    );
    if (q.length < 2) {
      return Response.json({ query: q, categories: [], links: [] });
    }
    const scope = scopeRaw === "links" || scopeRaw === "categories"
      ? scopeRaw
      : "both";
    try {
      const { categories, links } = await getClient().search(q, {
        limit,
        scope,
      });
      return Response.json({ query: q, scope, categories, links });
    } catch (e) {
      console.error("admin search failed:", e);
      return Response.json({ error: String(e) }, { status: 500 });
    }
  },
});
