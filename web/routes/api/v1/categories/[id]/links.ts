import { define } from "../../../../../utils.ts";
import { getClient } from "../../../../../lib/dmoz-client.ts";
import { parseEntityId } from "../../../../../lib/utils.ts";
import {
  afterCursor,
  badRequest,
  cursorMessage,
  errorResponse,
  linkJson,
  PAGE_SIZE_MESSAGE,
  pageSize,
} from "../../_lib/api.ts";

export const handler = define.handlers({
  async GET(ctx) {
    const categoryId = parseEntityId(ctx.params.id);
    if (categoryId === undefined) return badRequest("invalid category id");

    const { searchParams } = ctx.url;
    const afterId = afterCursor(searchParams.get("after_id"));
    const limit = pageSize(searchParams.get("limit"));
    if (afterId === undefined) return badRequest(cursorMessage("after_id"));
    if (limit === undefined) return badRequest(PAGE_SIZE_MESSAGE);

    try {
      const page = await getClient().listSubtreeLinks(categoryId, {
        afterId,
        limit,
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
