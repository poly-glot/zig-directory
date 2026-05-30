import Eyebrow from "../../common/Eyebrow/Eyebrow.tsx";
import RecentQueries from "../../../islands/RecentQueries.tsx";
import styles from "./Hero.module.css";

interface Props {
  query: string;
  categoryCount: number;
  linkCount: number;
  filteredCount: number;
  hasFilters: boolean;
  /** True when categoryCount or linkCount sits at the server cap. */
  capped: boolean;
}

const SEARCH_GLYPH = (
  <span class="icon" aria-hidden="true">
    <svg
      width="14"
      height="14"
      viewBox="0 0 14 14"
      fill="none"
      stroke="currentColor"
      stroke-width="1.4"
    >
      <circle cx="6" cy="6" r="4.5" />
      <path d="M9.5 9.5l3 3" />
    </svg>
  </span>
);

function ResultCount(
  { categoryCount, linkCount, filteredCount, hasFilters, capped }: {
    categoryCount: number;
    linkCount: number;
    filteredCount: number;
    hasFilters: boolean;
    capped: boolean;
  },
) {
  if (hasFilters) {
    return (
      <>
        Showing <strong>{filteredCount}</strong> of {linkCount}{" "}
        matching links — filters applied
      </>
    );
  }
  const parts: preact.ComponentChildren[] = [];
  if (categoryCount > 0) {
    parts.push(
      <>
        <strong>{categoryCount}</strong>{" "}
        {categoryCount === 1 ? "category" : "categories"}
      </>,
    );
  }
  if (linkCount > 0) {
    parts.push(
      <>
        <strong>{linkCount}</strong> {linkCount === 1 ? "link" : "links"}
      </>,
    );
  }
  return (
    <>
      Showing {parts.map((p, i) => (
        <span key={i}>
          {i > 0 ? " and " : null}
          {p}
        </span>
      ))}
      {capped
        ? (
          <span class={styles.cappedHint}>
            {" "}— refine your query to narrow further
          </span>
        )
        : null}
    </>
  );
}

export default function Hero(
  {
    query,
    categoryCount,
    linkCount,
    filteredCount,
    hasFilters,
    capped,
  }: Props,
) {
  const hasQuery = query.length > 0;
  const totalShown = categoryCount + linkCount;
  return (
    <section class={styles.hero}>
      <div class="container">
        <Eyebrow label="Search the index" muted />
        <h1 class="display mt-16">Find a site by keyword.</h1>
        <p class="lede mt-16">
          Editor-vetted results from the directory's full-text index. AND-of-
          tokens, ID-ordered.
        </p>
        <form
          action="/search"
          method="GET"
          class={`search-wrap mt-32 ${styles.searchWide}`}
        >
          {SEARCH_GLYPH}
          <input
            type="text"
            name="q"
            value={query}
            placeholder="public domain"
            autocomplete="off"
          />
          <button type="submit" class="btn">Search</button>
        </form>
        <RecentQueries />
        {hasQuery && totalShown > 0
          ? (
            <div class={styles.count}>
              <ResultCount
                categoryCount={categoryCount}
                linkCount={linkCount}
                filteredCount={filteredCount}
                hasFilters={hasFilters}
                capped={capped}
              />
            </div>
          )
          : null}
      </div>
    </section>
  );
}
