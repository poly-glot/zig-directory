import { define } from "../../utils.ts";
import { getClient } from "../../lib/dmoz-client.ts";

// Server-side listStructs hard-caps `listChildren` at 100, so anything
// above is wishful. Submit's /submit dropdown shares this limit — keep
// them aligned so the two callers don't disagree about what the picker
// can render. Topics with >100 children silently truncate today; add
// pagination here when that becomes a real concern.
const SUBCATEGORY_LIMIT = 100;

export const handler = define.handlers({
  async GET(ctx) {
    const raw = ctx.url.searchParams.get("parentId") ?? "";
    const parentId = parseInt(raw, 10);
    if (!Number.isFinite(parentId) || parentId <= 0) {
      return Response.json({ children: [] });
    }
    try {
      const children = await getClient().listChildren(
        parentId,
        0,
        SUBCATEGORY_LIMIT,
      );
      return Response.json({
        children: children.map((c) => ({ id: c.id, name: c.name })),
      });
    } catch (e) {
      console.error("category-children failed:", e);
      return Response.json({ children: [], error: String(e) }, { status: 500 });
    }
  },
});
