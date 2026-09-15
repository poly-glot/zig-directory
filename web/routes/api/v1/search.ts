import { define } from "../../../utils.ts";
import { getClient } from "../../../lib/dmoz-client.ts";
import {
  categoryJson,
  categoryPath,
  errorResponse,
  linkJson,
  pageSize,
} from "./_lib/api.ts";

type Scope = "both" | "links" | "categories";

const MIN_QUERY_LENGTH = 2;
const MATCHED_FIELD = ["title", "url", "description"] as const;

function parseScope(raw: string | null): Scope {
  if (raw === "links" || raw === "categories") return raw;
  return "both";
}

export const handler = define.handlers({
  async GET(ctx) {
    const { searchParams } = ctx.url;
    const query = (searchParams.get("q") ?? "").trim();
    if (query.length < MIN_QUERY_LENGTH) {
      return Response.json(
        { error: `q must be at least ${MIN_QUERY_LENGTH} characters` },
        { status: 400 },
      );
    }
    try {
      const client = getClient();
      const result = await client.search(query, {
        limit: pageSize(searchParams.get("limit")),
        scope: parseScope(searchParams.get("scope")),
      });
      const chains = await client.breadcrumbsByIds([
        ...result.categories.map((c) => c.id),
        ...result.links.map((l) => l.categoryId),
      ]);
      return Response.json({
        query,
        categories: result.categories.map((c) =>
          categoryJson(c, categoryPath(chains.get(c.id) ?? []))
        ),
        links: result.links.map((l) => ({
          ...linkJson(l),
          categoryPath: categoryPath(chains.get(l.categoryId) ?? []),
          matchedField: MATCHED_FIELD[l.matchField] ?? "title",
        })),
      });
    } catch (e) {
      return errorResponse(e);
    }
  },
});
