import { define } from "../../../utils.ts";
import { getClient } from "../../../lib/dmoz-client.ts";

// POST /admin/api/bulk-delete-categories  body: { ids: number[] }
// → { ok, errors: [{ id, code, message }] }.
//
// There is no server-side bulk-delete-categories op, and category ids share
// no id space with links, so categories must NOT use the link bulk-delete
// endpoint. This loops client.deleteCategory per id; the server rejects any
// category that still has children or links (CategoryHasChildren), which
// enforces the "zero-descendants only" rule server-side.
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
    const client = getClient();
    const errors: Array<{ id: number; code: number; message: string }> = [];
    let ok = 0;
    for (const id of body.ids) {
      try {
        await client.deleteCategory(id);
        ok++;
      } catch (e) {
        errors.push({ id, code: -1, message: String(e) });
      }
    }
    return Response.json({ ok, errors });
  },
});
