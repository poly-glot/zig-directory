import { define } from "../../../utils.ts";
import { getClient } from "../../../lib/dmoz-client.ts";

// POST /admin/api/bulk-move  body: { ids: number[], categoryId: number }
// → { ok, errors: [{ id, code, message }] }.
//
// There is no server-side bulk-move op (spec non-goal), so this loops
// client.moveLink per id and collects partial failures. code is -1 for any
// move failure; the message carries the underlying dmozdb error.
export const handler = define.handlers({
  async POST(ctx) {
    const body = await ctx.req.json().catch(() => null);
    if (
      !body || !Array.isArray(body.ids) || body.ids.length === 0 ||
      body.ids.length > 200 ||
      !body.ids.every((x: unknown) => typeof x === "number") ||
      typeof body.categoryId !== "number"
    ) {
      return Response.json({ error: "bad request" }, { status: 400 });
    }
    const client = getClient();
    const errors: Array<{ id: number; code: number; message: string }> = [];
    let ok = 0;
    for (const id of body.ids) {
      try {
        await client.moveLink(id, body.categoryId);
        ok++;
      } catch (e) {
        errors.push({ id, code: -1, message: String(e) });
      }
    }
    return Response.json({ ok, errors });
  },
});
