import { define } from "../../../../../utils.ts";
import { getClient } from "../../../../../lib/dmoz-client.ts";
import { verifyBearerToken } from "../../../../../lib/oauth.ts";
import { errorResponse, linkJson } from "../../_lib/api.ts";

function bearerToken(req: Request): string | null {
  const header = req.headers.get("authorization") ?? "";
  const [scheme, token] = header.split(" ");
  return scheme?.toLowerCase() === "bearer" && token ? token : null;
}

export const handler = define.handlers({
  async POST(ctx) {
    const token = bearerToken(ctx.req);
    const identity = token ? await verifyBearerToken(token) : null;
    if (!identity) {
      return Response.json({ error: "unauthorized" }, { status: 401 });
    }
    if (identity.role !== "admin") {
      return Response.json({ error: "forbidden" }, { status: 403 });
    }

    const id = parseInt(ctx.params.id, 10);
    if (!Number.isFinite(id) || id <= 0) {
      return Response.json({ error: "invalid link id" }, { status: 400 });
    }

    let body: { status?: unknown };
    try {
      body = await ctx.req.json();
    } catch {
      return Response.json({ error: "invalid JSON body" }, { status: 400 });
    }
    if (body.status !== "approved" && body.status !== "rejected") {
      return Response.json(
        { error: 'status must be "approved" or "rejected"' },
        { status: 400 },
      );
    }

    try {
      const client = getClient();
      await client.updateLinkStatus(id, body.status);
      const link = await client.getLink(id);
      return Response.json(linkJson(link));
    } catch (e) {
      return errorResponse(e);
    }
  },
});
