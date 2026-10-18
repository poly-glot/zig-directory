import { DmozClient } from "../../web/lib/dmoz-client.ts";

const BATCH = 200;
const LINK_PAGE = 500;
const MISSING_IDS_BEFORE_STOP = 5000;

const host = Deno.env.get("DMOZDB_HOST") ?? "127.0.0.1";
const port = Number(Deno.env.get("DMOZDB_PORT") ?? 18080);
const outDir = new URL(
  Deno.env.get("EXPORT_DIR") ?? "./data/",
  new URL("./", import.meta.url),
);
const client = new DmozClient(host, port);

async function exportCategories(): Promise<number> {
  const lines: string[] = [];
  let lastFound = 0;

  for (
    let start = 1;
    start - lastFound <= MISSING_IDS_BEFORE_STOP;
    start += BATCH
  ) {
    const ids = Array.from({ length: BATCH }, (_, i) => start + i);
    const categories = await client.getCategoriesByIds(ids);
    const crumbs = await client.breadcrumbsByIds(categories.map((c) => c.id));

    for (const c of categories) {
      lastFound = Math.max(lastFound, c.id);
      lines.push(JSON.stringify({
        id: c.id,
        parent_id: c.parentId,
        name: c.name,
        slug: c.slug,
        description: c.description,
        path: (crumbs.get(c.id) ?? []).map((crumb) => crumb.name),
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

async function exportLinks(): Promise<number> {
  const lines: string[] = [];
  let afterId = 0;

  do {
    const page = await client.listAllLinks({ limit: LINK_PAGE, afterId });
    for (const link of page.links) {
      lines.push(JSON.stringify({
        id: link.id,
        category_id: link.categoryId,
        url: link.url,
        title: link.title,
        description: link.description,
        status: link.status,
      }));
    }
    afterId = page.nextAfterId;
  } while (afterId !== 0);

  await Deno.writeTextFile(
    new URL("links.jsonl", outDir),
    lines.join("\n") + "\n",
  );
  return lines.length;
}

await Deno.mkdir(outDir, { recursive: true });
const categories = await exportCategories();
const links = await exportLinks();
console.log(
  JSON.stringify({ categories, links, expected: await client.stats() }),
);
Deno.exit(0);
