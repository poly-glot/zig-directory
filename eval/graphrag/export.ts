import { DmozClient } from "../../web/lib/dmoz-client.ts";

const BATCH = 200;
const ID_HEADROOM = 64;

const host = Deno.env.get("DMOZDB_HOST") ?? "127.0.0.1";
const port = Number(Deno.env.get("DMOZDB_PORT") ?? 18080);
const outDir = new URL("./data/", import.meta.url);
const client = new DmozClient(host, port);

async function exportCategories(maxId: number): Promise<number> {
  const lines: string[] = [];

  for (let start = 1; start <= maxId; start += BATCH) {
    const ids = Array.from(
      { length: Math.min(BATCH, maxId - start + 1) },
      (_, i) => start + i,
    );
    const categories = await client.getCategoriesByIds(ids);
    const crumbs = await client.breadcrumbsByIds(categories.map((c) => c.id));

    for (const c of categories) {
      const path = (crumbs.get(c.id) ?? []).map((crumb) => crumb.name);
      lines.push(JSON.stringify({
        id: c.id,
        parent_id: c.parentId,
        name: c.name,
        slug: c.slug,
        description: c.description,
        path,
        link_count: c.linkCount,
        link_count_subtree: c.linkCountSubtree,
      }));
    }
  }

  await Deno.writeTextFile(
    new URL("categories.jsonl", outDir),
    lines.join("\n") + "\n",
  );
  return lines.length;
}

async function exportLinks(maxId: number): Promise<number> {
  const lines: string[] = [];

  for (let id = 1; id <= maxId; id++) {
    const link = await client.getLink(id).catch(() => null);
    if (!link) continue;

    lines.push(JSON.stringify({
      id: link.id,
      category_id: link.categoryId,
      url: link.url,
      title: link.title,
      description: link.description,
      status: link.status,
    }));
  }

  await Deno.writeTextFile(
    new URL("links.jsonl", outDir),
    lines.join("\n") + "\n",
  );
  return lines.length;
}

const stats = await client.stats();
const categoryCount = await exportCategories(stats.categoryCount + ID_HEADROOM);
const linkCount = await exportLinks(stats.linkCount + ID_HEADROOM);
console.log(
  JSON.stringify({
    categories: categoryCount,
    links: linkCount,
    expected: stats,
  }),
);
