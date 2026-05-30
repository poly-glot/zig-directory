import { define } from "../../../utils.ts";
import { getClient, type LinkStatus } from "../../../lib/dmoz-client.ts";

function validStatus(s: unknown): s is LinkStatus {
  return s === "pending" || s === "approved" || s === "rejected";
}

// POST /admin/api/bulk-status  body: { ids: number[], status: LinkStatus }
// → { ok, errors: [{ id, code }] }. Cap 200 (matches the server op).
export const handler = define.handlers({
  async POST(ctx) {
    const body = await ctx.req.json().catch(() => null);
    if (
      !body || !Array.isArray(body.ids) || body.ids.length === 0 ||
      body.ids.length > 200 ||
      !body.ids.every((x: unknown) => typeof x === "number") ||
      !validStatus(body.status)
    ) {
      return Response.json({ error: "bad request" }, { status: 400 });
    }
    try {
      const result = await getClient().bulkUpdateLinkStatus(
        body.ids,
        body.status,
      );
      return Response.json(result);
    } catch (e) {
      console.error("bulk-status failed:", e);
      return Response.json({ error: String(e) }, { status: 500 });
    }
  },
});
