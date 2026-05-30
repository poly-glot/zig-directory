import { page } from "fresh";
import { define } from "../utils.ts";
import {
  type Category,
  type DbStats,
  getClient,
  type Link,
} from "../lib/dmoz-client.ts";
import HomeHero from "../components/home/HomeHero/HomeHero.tsx";
import HomeCategoriesSection from "../components/home/HomeCategoriesSection/HomeCategoriesSection.tsx";
import HomeRecentSection, {
  type LinkWithCategory,
} from "../components/home/HomeRecentSection/HomeRecentSection.tsx";
import HomeStatsSection from "../components/home/HomeStatsSection/HomeStatsSection.tsx";
import HomeContributeSection from "../components/home/HomeContributeSection/HomeContributeSection.tsx";

interface Data {
  categories: Category[];
  featuredLinks: LinkWithCategory[];
  dbStats: DbStats | null;
  error?: string;
}

async function loadEntryCategories(
  client: ReturnType<typeof getClient>,
): Promise<Category[]> {
  let categories = await client.listRootCategories(0, 100);
  // DMOZ data has exactly one root (Top); useful entry points are Top's
  // children. Drill one level when the root set is a singleton.
  if (categories.length === 1) {
    try {
      const children = await client.listChildren(categories[0].id, 0, 100);
      if (children.length > 0) categories = children;
    } catch {
      // fall back to single root
    }
  }
  return categories;
}

async function annotateLinks(
  client: ReturnType<typeof getClient>,
  links: Link[],
): Promise<LinkWithCategory[]> {
  // One batched fetch instead of one getCategory per unique categoryId.
  const uniqueIds = [...new Set(links.map((l) => l.categoryId))]
    .filter((id) => id > 0);
  const cache = new Map<number, { name: string; linkCountSubtree: number }>();
  if (uniqueIds.length > 0) {
    try {
      const cats = await client.getCategoriesByIds(uniqueIds);
      for (const c of cats) {
        cache.set(c.id, { name: c.name, linkCountSubtree: c.linkCountSubtree });
      }
    } catch (e) {
      console.error("annotateLinks: getCategoriesByIds failed:", e);
    }
  }
  return links.map((link) => {
    const entry = cache.get(link.categoryId) ??
      { name: "", linkCountSubtree: 0 };
    return {
      ...link,
      categoryName: entry.name,
      categoryLinkCountSubtree: entry.linkCountSubtree,
    };
  });
}

async function loadStatsSafe(
  client: ReturnType<typeof getClient>,
): Promise<DbStats | null> {
  // Stats failure is non-fatal — the dark section is hidden when null,
  // hero stat row falls back to em-dashes.
  try {
    return await client.stats();
  } catch (e) {
    console.error("Failed to load db stats:", e);
    return null;
  }
}

async function loadHomepage(): Promise<Data> {
  const client = getClient();
  const categories = await loadEntryCategories(client);
  // HomeRecentSection renders the first 6. Pulling 24 was over-fetch.
  const { links: allLinks } = await client.listAllLinks({ limit: 6 });
  const featuredLinks = await annotateLinks(client, allLinks);
  const dbStats = await loadStatsSafe(client);
  return { categories, featuredLinks, dbStats };
}

export const handler = define.handlers<Data>({
  async GET() {
    try {
      return page(await loadHomepage());
    } catch (e) {
      console.error("Failed to load homepage data:", e);
      return page({
        categories: [],
        featuredLinks: [],
        dbStats: null,
        error: "Directory service unavailable",
      });
    }
  },
});

export default define.page<typeof handler>(function HomePage(props) {
  const { categories, featuredLinks, dbStats, error } = props.data;
  const totalLinks = dbStats?.linkCount ?? 0;
  return (
    <>
      <HomeHero dbStats={dbStats} error={error} />
      <HomeCategoriesSection categories={categories} />
      <HomeRecentSection
        featuredLinks={featuredLinks}
        totalLinks={totalLinks}
      />
      {dbStats ? <HomeStatsSection dbStats={dbStats} /> : null}
      <HomeContributeSection />
    </>
  );
});
