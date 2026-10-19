import { define } from "../../../utils.ts";
import { type DmozClient, getClient } from "../../../lib/dmoz-client.ts";
import { loadEntryCategories } from "../../../lib/entry-categories.ts";
import { categoryPath } from "../../../lib/format.ts";
import { categoryJson, categoryNotFound, errorResponse } from "./_lib/api.ts";

async function browseRoot(client: DmozClient) {
  const { root, categories } = await loadEntryCategories(client);
  const chain = root ? [root] : [];
  return {
    category: root ? categoryJson(root, "") : null,
    ancestors: [],
    children: categories.map((c) =>
      categoryJson(c, categoryPath([...chain, c]))
    ),
    totalLinksInSubtree: root?.linkCountSubtree ?? 0,
  };
}

async function browseCategory(client: DmozClient, path: string) {
  const result = await client.browsePathIfFound(path);
  if (!result) return undefined;

  const chain = [...result.ancestors, result.category];
  return {
    category: categoryJson(result.category, categoryPath(chain)),
    ancestors: result.ancestors.map((a, i) =>
      categoryJson(a, categoryPath(chain.slice(0, i + 1)))
    ),
    children: result.children.map((child) =>
      categoryJson(child, categoryPath([...chain, child]))
    ),
    totalLinksInSubtree: result.totalLinksInSubtree,
  };
}

export const handler = define.handlers({
  async GET(ctx) {
    const path = (ctx.url.searchParams.get("path") ?? "").trim();
    const client = getClient();
    try {
      if (path === "") return Response.json(await browseRoot(client));
      const browsed = await browseCategory(client, path);
      return browsed ? Response.json(browsed) : categoryNotFound(path);
    } catch (e) {
      return errorResponse(e);
    }
  },
});
