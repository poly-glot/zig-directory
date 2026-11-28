import { page } from "fresh";
import { define } from "../../utils.ts";
import {
  type Crumb,
  type DmozClient,
  getClient,
  type Link,
  QUERY_LINKS_MAX_ROWS,
  SEARCH_QUERY_MAX_CHARS,
  type SearchLink,
  type SearchResult,
} from "../../lib/dmoz-client.ts";
import { embedQuery } from "../../lib/embedder.ts";
import { searchFailure } from "./_lib/failure.ts";
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
  isOnlyAGuessedRole,
  linkQueryFor,
  namePhrases,
  neighbourAsks,
  neighbourChip,
  rankedQuery,
  recognise,
  type Target,
  typedTargets,
  type Understanding,
  unmatched,
} from "./_lib/targets.ts";
import { queryVocabulary } from "../../lib/entities.ts";
import { categoryPath } from "../../lib/format.ts";
import { logSearch, type Stopwatch, stopwatch } from "../../lib/timing.ts";
import type {
  Chip,
  Facets,
  LinkCounts,
  Relaxation,
  Sort,
  Suggestion,
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
  suggestions: Suggestion[];
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

const SUGGESTION_CHIPS = 8;

async function suggestionsFor(
  client: DmozClient,
  targets: readonly Target[],
): Promise<Suggestion[]> {
  const asks = neighbourAsks(targets);
  if (asks.length === 0) return [];

  const vocabulary = await queryVocabulary();
  const suggestions: Suggestion[] = [];
  for (const ask of asks) {
    const of = ask.kind === "category"
      ? { categoryId: ask.target.categoryId }
      : { name: ask.target.value };
    const neighbours = await client.neighbours(ask.kind, {
      ...of,
      limit: SUGGESTION_CHIPS,
    }).catch(() => null) ?? [];

    const categoryIds = neighbours.map((n) => n.categoryId).filter(Boolean);
    const chains = categoryIds.length > 0
      ? await client.breadcrumbsByIds(categoryIds)
      : new Map<number, Crumb[]>();

    const chips = neighbours.flatMap((neighbour) => {
      const chain = chains.get(neighbour.categoryId);
      const named = chain
        ? {
          label: buildPathLabel(neighbour.categoryId, chains),
          raw: categoryPath(chain),
        }
        : { label: neighbour.label, raw: neighbour.label };
      return neighbourChip(ask, named, vocabulary) ?? [];
    });
    if (chips.length > 0) suggestions.push({ heading: ask.heading, chips });
  }
  return suggestions;
}

async function buildTargetedResult(
  base: Data,
  understanding: Understanding,
  after: number,
  watch: Stopwatch,
): Promise<Data> {
  const client = getClient();
  const resolved = await watch.time(
    "category",
    () => withCategoryPath(client, understanding.targets),
  );
  if ("missing" in resolved) {
    return { ...base, error: unmatched("category", resolved.missing) };
  }

  const { targets, label } = resolved;
  const { words } = understanding;
  const result = await watch.time("facts", () =>
    client.queryLinks({
      ...linkQueryFor(targets, words),
      limit: QUERY_LINKS_MAX_ROWS,
      afterId: after,
    }));
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
    ? await watch.time("relaxed", () =>
      Promise.all(
        constraints.map((c) =>
          client.queryLinks({ ...linkQueryFor(c.targets, c.words), limit: 0 })
        ),
      ))
    : [];

  const suggestions = after === 0
    ? await watch.time("neighbours", () => suggestionsFor(client, targets))
    : [];

  return {
    ...base,
    filtered: {
      suggestions,
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
  watch: Stopwatch,
): Promise<Data> {
  const client = getClient();
  const ranked = rankedQuery(q);
  const queryEmbedding = await watch.time("embed", () => embedQuery(ranked));
  const rawResults = await watch.time("search", () =>
    client.search(ranked, {
      limit: 50,
      mode: "ranked",
      capPerSite: true,
      queryEmbedding,
    }));

  const crumbIds = new Set<number>();
  for (const c of rawResults.categories) crumbIds.add(c.id);
  for (const l of rawResults.links) crumbIds.add(l.categoryId);
  const chains = await watch.time(
    "crumbs",
    () => client.breadcrumbsByIds([...crumbIds]),
  );
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

function timed(data: Data, watch: Stopwatch) {
  return page(data, { headers: { "Server-Timing": watch.serverTiming() } });
}

export const handler = define.handlers<Data>({
  async GET(ctx) {
    const url = ctx.url;
    const q = url.searchParams.get("q")?.trim() ?? "";
    const sort = parseSort(url.searchParams.get("sort"));
    const cat = parsePositiveInt(url.searchParams.get("cat"));
    const year = parsePositiveInt(url.searchParams.get("year"));

    if (q.length > SEARCH_QUERY_MAX_CHARS) {
      ctx.state.title = "Search";
      return page({
        ...emptyData("", sort, cat, year),
        error: `Search for at most ${SEARCH_QUERY_MAX_CHARS} characters.`,
      }, { status: 400 });
    }

    ctx.state.title = q ? `Search: ${q}` : "Search";

    if (!q) return page(emptyData(q, sort, cat, year));

    try {
      const watch = stopwatch();
      if (url.searchParams.get("plain") !== "1") {
        const understanding = await watch.time(
          "understand",
          () => understand(q),
        );
        const base = emptyData(q, sort, cat, year);
        if (understanding.error) {
          return page({ ...base, error: understanding.error });
        }
        if (understanding.targets.length > 0) {
          const after = parsePositiveInt(url.searchParams.get("after"));
          const data = await buildTargetedResult(
            base,
            understanding,
            after,
            watch,
          );
          const nothingFiledAsRole = data.filtered?.counts.total === 0 &&
            isOnlyAGuessedRole(q, understanding.targets);
          if (!nothingFiledAsRole) {
            logSearch({
              query: q,
              path: "targeted",
              links: data.filtered?.links.length ?? 0,
              categories: 0,
              watch,
            });
            return timed(data, watch);
          }
        }
      }

      const data = await buildSearchResult(q, sort, cat, year, watch);
      logSearch({
        query: q,
        path: "ranked",
        links: data.rawResults.links.length,
        categories: data.rawResults.categories.length,
        watch,
      });
      return timed(data, watch);
    } catch (e) {
      const failure = searchFailure(e);
      return page({
        ...emptyData(q, sort, cat, year),
        error: failure.error,
      }, { status: failure.status });
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
          suggestions={filtered.suggestions}
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
