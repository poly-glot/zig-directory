import { page } from "fresh";
import { define } from "../../utils.ts";
import {
  type DmozClient,
  getClient,
  type Link,
  QUERY_LINKS_MAX_ROWS,
  type SearchLink,
  type SearchResult,
} from "../../lib/dmoz-client.ts";
import { embedQuery } from "../../lib/embedder.ts";
import { tokensFor } from "./_lib/highlight.tsx";
import {
  buildHref,
  parsePositiveInt,
  parseSort,
  searchHref,
} from "./_lib/queryParams.ts";
import {
  applyFilters,
  applySort,
  buildPathLabel,
  computeCategoryFacet,
  computeYearFacet,
} from "./_lib/facets.ts";
import {
  canonicalQuery,
  constraintsOf,
  linkQueryFor,
  namePhrases,
  rankedQuery,
  recognise,
  type Target,
  typedTargets,
  type Understanding,
  unmatched,
} from "./_lib/targets.ts";
import { queryVocabulary } from "../../lib/entities.ts";
import { categoryPath } from "../../lib/format.ts";
import type {
  Chip,
  Facets,
  LinkCounts,
  Relaxation,
  Sort,
} from "./_lib/types.ts";
import Hero from "../../components/search/Hero/Hero.tsx";
import ResultsBody from "../../components/search/ResultsBody/ResultsBody.tsx";
import FilteredResults, {
  FilteredCount,
} from "../../components/search/FilteredResults/FilteredResults.tsx";

interface Filtered {
  counts: LinkCounts;
  chips: Chip[];
  relaxations: Relaxation[];
  plainHref: string;
  words: string[];
  links: Link[];
  nextHref?: string;
}

interface Data {
  query: string;
  rawResults: SearchResult;
  filteredLinks: SearchLink[];
  facets: Facets;
  sort: Sort;
  /** id → breadcrumb-style path label (e.g. `Arts › Visual_Arts › Drawing`).
   * Built for every result category so the on-page list can distinguish
   * identically-named categories that live in different subtrees. */
  categoryPaths: Record<number, string>;
  error?: string;
  filtered?: Filtered;
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

function emptyData(q: string, sort: Sort, cat: number, year: number): Data {
  return {
    query: q,
    rawResults: { categories: [], links: [], vectorUsed: false },
    filteredLinks: [],
    facets: emptyFacets(q, sort, cat, year),
    sort,
    categoryPaths: {},
  };
}

async function understand(q: string): Promise<Understanding> {
  const vocabulary = await queryVocabulary();
  const typed = typedTargets(q, vocabulary);
  if (typed.error) return { targets: [], words: [], error: typed.error };

  const phrases = namePhrases(typed.text, vocabulary);
  const matches = phrases.length > 0
    ? await getClient().matchNames(phrases)
    : null;
  const names = new Map(
    matches ? phrases.map((phrase, i) => [phrase, matches[i]] as const) : [],
  );
  return recognise(typed.text, typed.targets, vocabulary, names);
}

async function withCategoryPath(
  client: DmozClient,
  targets: Target[],
): Promise<{ targets: Target[]; label: string } | { missing: string }> {
  const at = targets.findIndex((target) => target.kind === "category");
  if (at < 0) return { targets, label: "" };

  const target = targets[at];
  const id = target.categoryId ??
    (await client.browsePathIfFound(target.value))?.category.id;
  if (id === undefined) return { missing: target.value };

  const chains = await client.breadcrumbsByIds([id]);
  const path = categoryPath(chains.get(id) ?? []);
  return {
    targets: targets.with(at, { ...target, categoryId: id, value: path }),
    label: buildPathLabel(id, chains),
  };
}

async function buildTargetedResult(
  base: Data,
  understanding: Understanding,
  after: number,
): Promise<Data> {
  const client = getClient();
  const resolved = await withCategoryPath(client, understanding.targets);
  if ("missing" in resolved) {
    return { ...base, error: unmatched("category", resolved.missing) };
  }

  const { targets, label } = resolved;
  const { words } = understanding;
  const result = await client.queryLinks({
    ...linkQueryFor(targets, words),
    limit: QUERY_LINKS_MAX_ROWS,
    afterId: after,
  });
  if (!result.ready) {
    return { ...base, error: "Link facts are still loading, retry shortly" };
  }

  const constraints = constraintsOf(targets, words, label);
  const chips = constraints.map((c) => ({
    label: c.label,
    href: searchHref({ q: canonicalQuery(c.targets, c.words) }),
  }));
  const relaxable = result.total === 0 && constraints.length > 1;
  const relaxed = relaxable
    ? await Promise.all(
      constraints.map((c) =>
        client.queryLinks({ ...linkQueryFor(c.targets, c.words), limit: 0 })
      ),
    )
    : [];

  return {
    ...base,
    filtered: {
      counts: {
        total: result.total,
        sites: result.sites,
        hosts: result.hosts,
        domains: result.domains,
      },
      chips,
      relaxations: relaxed
        .map((r, i) => ({ ...chips[i], links: r.total }))
        .filter((r) => r.links > 0),
      plainHref: searchHref({ q: base.query, plain: "1" }),
      words,
      links: result.links,
      nextHref: result.nextAfterId > 0
        ? searchHref({ q: base.query, after: String(result.nextAfterId) })
        : undefined,
    },
  };
}

async function buildSearchResult(
  q: string,
  sort: Sort,
  cat: number,
  year: number,
): Promise<Data> {
  const client = getClient();
  const ranked = rankedQuery(q);
  const rawResults = await client.search(ranked, {
    limit: 50,
    mode: "ranked",
    capPerSite: true,
    queryEmbedding: await embedQuery(ranked),
  });
  const crumbIds = new Set<number>();
  for (const c of rawResults.categories) crumbIds.add(c.id);
  for (const l of rawResults.links) crumbIds.add(l.categoryId);
  const chains = await client.breadcrumbsByIds([...crumbIds]);
  const categoryPaths: Record<number, string> = {};
  for (const c of rawResults.categories) {
    categoryPaths[c.id] = buildPathLabel(c.id, chains);
  }
  const filteredLinks = applySort(
    applyFilters(rawResults.links, cat, year),
    sort,
  );
  const facets: Facets = {
    categories: computeCategoryFacet(
      rawResults.links,
      chains,
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

    if (!q) return page(emptyData(q, sort, cat, year));

    try {
      if (url.searchParams.get("plain") !== "1") {
        const understanding = await understand(q);
        const base = emptyData(q, sort, cat, year);
        if (understanding.error) {
          return page({ ...base, error: understanding.error });
        }
        if (understanding.targets.length > 0) {
          const after = parsePositiveInt(url.searchParams.get("after"));
          return page(await buildTargetedResult(base, understanding, after));
        }
      }
      return page(await buildSearchResult(q, sort, cat, year));
    } catch (e) {
      console.error("Search failed:", e);
      return page({
        ...emptyData(q, sort, cat, year),
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
    filtered,
  } = props.data;

  if (filtered) {
    return (
      <>
        <Hero
          query={query}
          summary={<FilteredCount counts={filtered.counts} />}
        />
        <FilteredResults
          chips={filtered.chips}
          plainHref={filtered.plainHref}
          relaxations={filtered.relaxations}
          links={filtered.links}
          tokens={filtered.words}
          nextHref={filtered.nextHref}
        />
      </>
    );
  }

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
