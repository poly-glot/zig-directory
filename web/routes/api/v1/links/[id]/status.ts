import { define } from "../../../../../utils.ts";
import { getClient } from "../../../../../lib/dmoz-client.ts";
import { verifyBearerToken } from "../../../../../lib/oauth.ts";
import { bearerToken } from "../../../../../lib/session.ts";
import { parseEntityId } from "../../../../../lib/utils.ts";
import { badRequest, errorResponse, linkJson } from "../../_lib/api.ts";

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

    const id = parseEntityId(ctx.params.id);
    if (id === undefined) return badRequest("invalid link id");

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
