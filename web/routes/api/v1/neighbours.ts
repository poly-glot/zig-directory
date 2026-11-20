import { define } from "../../../utils.ts";
import {
  type DmozClient,
  getClient,
  MAX_ENTITY_NAME_BYTES,
  type Neighbour,
  type NeighbourKind,
  NEIGHBOURS_MAX,
} from "../../../lib/dmoz-client.ts";
import { categoryPath } from "../../../lib/format.ts";
import { categoryJson, categoryNotFound, errorResponse } from "./_lib/api.ts";

const KINDS: readonly NeighbourKind[] = ["site", "category", "entity"];
const HOST_SUFFIX = /^[a-z0-9-]+(\.[a-z0-9-]+)+$/;
const DEFAULT_LIMIT = 10;
const MAX_HOST_BYTES = 64;

function badRequest(error: string): Response {
  return Response.json({ error }, { status: 400 });
}

function limitOf(raw: string | null): number | undefined {
  if (raw === null || raw === "") return DEFAULT_LIMIT;
  const n = Number(raw);
  return Number.isInteger(n) && n >= 1 && n <= NEIGHBOURS_MAX ? n : undefined;
}

async function categoriesJson(client: DmozClient, neighbours: Neighbour[]) {
  const ids = neighbours.map((neighbour) => neighbour.categoryId);
  if (ids.length === 0) return [];

  const chains = await client.breadcrumbsByIds(ids);
  const categories = new Map(
    (await client.getCategoriesByIds(ids)).map((c) => [c.id, c]),
  );

  return neighbours.flatMap((neighbour) => {
    const category = categories.get(neighbour.categoryId);
    const chain = chains.get(neighbour.categoryId);
    if (!category || !chain) return [];
    return {
      ...categoryJson(category, categoryPath(chain)),
      sameName: neighbour.shared === 1,
    };
  });
}

export const handler = define.handlers({
  async GET(ctx) {
    const params = ctx.url.searchParams;
    const kind = KINDS.find((known) => known === params.get("kind"));
    const of = (params.get("of") ?? "").trim();
    const limit = limitOf(params.get("limit"));

    if (!kind) return badRequest(`kind must be one of ${KINDS}`);
    if (of === "") return badRequest("of names what to find neighbours of");
    if (limit === undefined) {
      return badRequest(`limit must be 1 to ${NEIGHBOURS_MAX}`);
    }

    try {
      const client = getClient();

      if (kind === "category") {
        const browsed = await client.browsePathIfFound(of);
        if (!browsed) return categoryNotFound(of);

        const neighbours = await client.neighbours(kind, {
          categoryId: browsed.category.id,
          limit,
        });
        if (!neighbours) return stillLoading();
        return Response.json({
          kind,
          of,
          neighbours: await categoriesJson(client, neighbours),
        });
      }

      const name = kind === "site" ? of.toLowerCase() : of;
      const bytes = new TextEncoder().encode(name).length;
      if (
        kind === "site" && (bytes > MAX_HOST_BYTES || !HOST_SUFFIX.test(name))
      ) {
        return badRequest("of must be a domain such as imdb.com");
      }
      if (kind === "entity" && bytes > MAX_ENTITY_NAME_BYTES) {
        return badRequest(`of must be at most ${MAX_ENTITY_NAME_BYTES} bytes`);
      }

      const neighbours = await client.neighbours(kind, { name, limit });
      if (!neighbours) return stillLoading();
      return Response.json({
        kind,
        of,
        neighbours: neighbours.map((neighbour) => ({
          name: neighbour.label,
          shared: neighbour.shared,
        })),
      });
    } catch (e) {
      return errorResponse(e);
    }
  },
});

function stillLoading(): Response {
  return Response.json(
    { error: "link facts are still loading, retry shortly" },
    { status: 503 },
  );
}
