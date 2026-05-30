import { define } from "../../../utils.ts";
import { getClient } from "../../../lib/dmoz-client.ts";

// POST /admin/api/bulk-delete  body: { ids: number[] }
// → { ok, errors: [{ id, code }] }. Cap 200 (matches the server op).
export const handler = define.handlers({
  async POST(ctx) {
    const body = await ctx.req.json().catch(() => null);
    if (
      !body || !Array.isArray(body.ids) || body.ids.length === 0 ||
      body.ids.length > 200 ||
      !body.ids.every((x: unknown) => typeof x === "number")
    ) {
      return Response.json({ error: "bad request" }, { status: 400 });
    }
    try {
      const result = await getClient().bulkDeleteLinks(body.ids);
      return Response.json(result);
    } catch (e) {
      console.error("bulk-delete failed:", e);
      return Response.json({ error: String(e) }, { status: 500 });
    }
  },
});
