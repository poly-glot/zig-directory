import { define } from "../../../../../utils.ts";
import { getClient } from "../../../../../lib/dmoz-client.ts";
import {
  errorResponse,
  linkJson,
  nonNegativeInt,
  pageSize,
} from "../../_lib/api.ts";

export const handler = define.handlers({
  async GET(ctx) {
    const categoryId = parseInt(ctx.params.id, 10);
    if (!Number.isFinite(categoryId) || categoryId <= 0) {
      return Response.json({ error: "invalid category id" }, { status: 400 });
    }
    const { searchParams } = ctx.url;
    try {
      const page = await getClient().listSubtreeLinks(categoryId, {
        afterId: nonNegativeInt(searchParams.get("after_id")),
        limit: pageSize(searchParams.get("limit")),
        status: "approved",
      });
      return Response.json({
        links: page.links.map(linkJson),
        total: page.total,
        nextAfterId: page.nextAfterId,
      });
    } catch (e) {
      return errorResponse(e);
    }
  },
});
