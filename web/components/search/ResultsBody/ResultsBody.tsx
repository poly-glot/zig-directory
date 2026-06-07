import type { Category, Link } from "../../../lib/dmoz-client.ts";
import CategoryRow from "../../common/CategoryRow/CategoryRow.tsx";
import SectionHead from "../../common/SectionHead/SectionHead.tsx";
import { pad2 } from "../../../lib/format.ts";
import type { Facets, Sort } from "../../../routes/search/_lib/types.ts";
import SortControl from "../SortControl/SortControl.tsx";
import ResultArticle from "../ResultArticle/ResultArticle.tsx";
import { EmptyPrompt, NoResults } from "../EmptyStates/EmptyStates.tsx";

interface Props {
  query: string;
  rawCats: Category[];
  allLinks: Link[];
  filteredLinks: Link[];
  tokens: string[];
  sort: Sort;
  activeCat: number;
  activeYear: number;
  facets: Facets;
  hasQuery: boolean;
  categoryPaths: Record<number, string>;
  error?: string;
}

const VISIBLE = 5;

function CatRow(
  { c, num, path }: { c: Category; num: string; path?: string },
) {
  // Use the breadcrumb path so two identically-named categories in
  // different subtrees stay distinguishable. CategoryRow runs
  // `formatCategoryName` on the label internally; the path is built
  // pre-formatted so the no-op is harmless.
  return (
    <CategoryRow
      num={num}
      href={`/category/${c.slug || c.id}`}
      name={path && path.length > 0 ? path : c.name}
      count={c.linkCountSubtree ?? c.linkCount}
    />
  );
}

function CategoriesSection(
  { cats, paths }: { cats: Category[]; paths: Record<number, string> },
) {
  if (cats.length === 0) return null;
  const head = cats.slice(0, VISIBLE);
  const rest = cats.slice(VISIBLE);
  return (
    <section class="section gray">
      <div class="container">
        <SectionHead
          num="01"
          topic="Categories"
          title="Browse by topic."
          lede="Editor-curated categories matching your query. Click through to see every link in a subject area."
        />
        <ul class="list list-bleed-borders">
          {head.map((c, i) => (
            <CatRow key={c.id} c={c} num={pad2(i + 1)} path={paths[c.id]} />
          ))}
        </ul>
        {rest.length > 0
          ? (
            <details class="search-view-all mt-16">
              <summary>View all {cats.length} categories</summary>
              <ul class="list list-bleed-borders mt-16">
                {rest.map((c, i) => (
                  <CatRow
                    key={c.id}
                    c={c}
                    num={pad2(VISIBLE + i + 1)}
                    path={paths[c.id]}
                  />
                ))}
              </ul>
            </details>
          )
          : null}
      </div>
    </section>
  );
}

function ListingsSection(
  {
    query,
    sort,
    activeCat,
    activeYear,
    filteredLinks,
    tokens,
    clearHref,
  }: {
    query: string;
    sort: Sort;
    activeCat: number;
    activeYear: number;
    filteredLinks: Link[];
    tokens: string[];
    clearHref: string;
  },
) {
  return (
    <section class="section">
      <div class="container">
        <div class="row between mb-24 flex-wrap gap-16">
          <SectionHead num="02" topic="Listings" title="Matching links." />
          <SortControl
            query={query}
            sort={sort}
            cat={activeCat}
            year={activeYear}
          />
        </div>
        {filteredLinks.length === 0
          ? (
            <div class="banner">
              No listings match the current filters.{" "}
              <a href={clearHref} class="under">Clear filters</a>.
            </div>
          )
          : (
            <div class="cards fluid">
              {filteredLinks.map((l) => (
                <ResultArticle key={l.id} link={l} tokens={tokens} />
              ))}
            </div>
          )}
      </div>
    </section>
  );
}

function SectionBanner(
  { children, tint }: { children: preact.ComponentChildren; tint?: boolean },
) {
  return (
    <section class={tint ? "section empty" : "section"}>
      <div class="container">{children}</div>
    </section>
  );
}

export default function ResultsBody(props: Props) {
  const {
    query,
    rawCats,
    allLinks,
    filteredLinks,
    tokens,
    sort,
    activeCat,
    activeYear,
    facets,
    hasQuery,
    categoryPaths,
    error,
  } = props;
  const totalRaw = rawCats.length + allLinks.length;

  if (error) {
    return (
      <SectionBanner>
        <div class="banner error">{error}</div>
      </SectionBanner>
    );
  }
  if (!hasQuery) {
    return (
      <SectionBanner tint>
        <ul class="list">
          <EmptyPrompt />
        </ul>
      </SectionBanner>
    );
  }
  if (totalRaw === 0) {
    return (
      <SectionBanner tint>
        <ul class="list">
          <NoResults query={query} />
        </ul>
      </SectionBanner>
    );
  }
  return (
    <>
      <CategoriesSection cats={rawCats} paths={categoryPaths} />
      {allLinks.length > 0
        ? (
          <ListingsSection
            query={query}
            sort={sort}
            activeCat={activeCat}
            activeYear={activeYear}
            filteredLinks={filteredLinks}
            tokens={tokens}
            clearHref={facets.clearCategoryHref}
          />
        )
        : null}
    </>
  );
}
