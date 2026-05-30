import { page } from "fresh";
import { define } from "../../utils.ts";
import {
  getClient,
  type Link,
  type SearchResult,
} from "../../lib/dmoz-client.ts";
import { tokensFor } from "./_lib/highlight.tsx";
import { buildHref, parsePositiveInt, parseSort } from "./_lib/queryParams.ts";
import {
  applyFilters,
  applySort,
  buildPathLabel,
  computeCategoryFacet,
  computeYearFacet,
} from "./_lib/facets.ts";
import { loadAncestorMap } from "./_lib/ancestors.ts";
import type { Facets, Sort } from "./_lib/types.ts";
import Hero from "../../components/search/Hero/Hero.tsx";
import ResultsBody from "../../components/search/ResultsBody/ResultsBody.tsx";

interface Data {
  query: string;
  rawResults: SearchResult;
  filteredLinks: Link[];
  facets: Facets;
  sort: Sort;
  /** id → breadcrumb-style path label (e.g. `Arts › Visual_Arts › Drawing`).
   * Built for every result category so the on-page list can distinguish
   * identically-named categories that live in different subtrees. */
  categoryPaths: Record<number, string>;
  error?: string;
}

function emptyFacets(q: string, sort: Sort, cat: number, year: number): Facets {
  return {
    categories: [],
    years: [],
    clearCategoryHref: buildHref({ q, sort }, {}),
    clearYearHref: buildHref({ q, sort }, { cat }),
    hasCategoryFilter: cat > 0,
    hasYearFilter: year > 0,
  };
}

async function buildSearchResult(
  q: string,
  sort: Sort,
  cat: number,
  year: number,
): Promise<Data> {
  const client = getClient();
  const rawResults = await client.search(q, { limit: 50 });
  const ancestors = await loadAncestorMap(
    client,
    rawResults.links.map((l) => l.categoryId),
    rawResults.categories,
  );
  const categoryPaths: Record<number, string> = {};
  for (const c of rawResults.categories) {
    categoryPaths[c.id] = buildPathLabel(c.id, ancestors);
  }
  const filteredLinks = applySort(
    applyFilters(rawResults.links, cat, year),
    sort,
  );
  const facets: Facets = {
    categories: computeCategoryFacet(
      rawResults.links,
      ancestors,
      q,
      sort,
      year,
      cat,
    ),
    years: computeYearFacet(rawResults.links, q, sort, cat, year),
    clearCategoryHref: buildHref({ q, sort }, { cat: null, year }),
    clearYearHref: buildHref({ q, sort }, { cat, year: null }),
    hasCategoryFilter: cat > 0,
    hasYearFilter: year > 0,
  };
  return { query: q, rawResults, filteredLinks, facets, sort, categoryPaths };
}

export const handler = define.handlers<Data>({
  async GET(ctx) {
    const url = ctx.url;
    const q = url.searchParams.get("q")?.trim() ?? "";
    const sort = parseSort(url.searchParams.get("sort"));
    const cat = parsePositiveInt(url.searchParams.get("cat"));
    const year = parsePositiveInt(url.searchParams.get("year"));

    ctx.state.title = q ? `Search: ${q}` : "Search";

    if (!q) {
      return page({
        query: "",
        rawResults: { categories: [], links: [] },
        filteredLinks: [],
        facets: emptyFacets(q, sort, cat, year),
        sort,
        categoryPaths: {},
      });
    }

    try {
      return page(await buildSearchResult(q, sort, cat, year));
    } catch (e) {
      console.error("Search failed:", e);
      return page({
        query: q,
        rawResults: { categories: [], links: [] },
        filteredLinks: [],
        facets: emptyFacets(q, sort, cat, year),
        sort,
        categoryPaths: {},
        error: "Search unavailable",
      });
    }
  },
});

export default define.page<typeof handler>(function SearchPage(props) {
  const {
    query,
    rawResults,
    filteredLinks,
    facets,
    sort,
    categoryPaths,
    error,
  } = props.data;
  const cats = rawResults.categories ?? [];
  const allLinks = rawResults.links ?? [];
  const tokens = tokensFor(query);
  const hasQuery = query.length > 0;
  const hasFilters = facets.hasCategoryFilter || facets.hasYearFilter;
  const activeCat = facets.categories.find((c) => c.active)?.id ?? 0;
  const activeYear = facets.years.find((y) => y.active)?.year ?? 0;
  // SEARCH_LIMIT mirrors `client.search(q, 50)` above. When either side
  // hits the cap, there are likely more matches the server didn't return.
  const SEARCH_LIMIT = 50;
  const capped = cats.length >= SEARCH_LIMIT ||
    allLinks.length >= SEARCH_LIMIT;

  return (
    <>
      <Hero
        query={query}
        categoryCount={cats.length}
        linkCount={allLinks.length}
        filteredCount={filteredLinks.length}
        hasFilters={hasFilters}
        capped={capped}
      />

      <ResultsBody
        query={query}
        rawCats={cats}
        allLinks={allLinks}
        filteredLinks={filteredLinks}
        tokens={tokens}
        sort={sort}
        activeCat={activeCat}
        activeYear={activeYear}
        facets={facets}
        hasQuery={hasQuery}
        categoryPaths={categoryPaths}
        error={error}
      />
    </>
  );
});
