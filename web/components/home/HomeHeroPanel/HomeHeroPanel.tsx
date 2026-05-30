import type { DbStats } from "../../../lib/dmoz-client.ts";
import styles from "./HomeHeroPanel.module.css";

interface Props {
  dbStats: DbStats | null;
  error?: string;
}

const TRENDING_CHIPS = [
  "Public domain",
  "Indie web",
  "Open data",
  "Archives",
] as const;

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

function StatCell({ label, value }: { label: string; value: string }) {
  return (
    <li class={styles.statCell}>
      <span class="micro">{label}</span>
      <span class={styles.statValue}>{value}</span>
    </li>
  );
}

function TrendingChips() {
  return (
    <div class={styles.trending}>
      <span class={styles.label}>Trending</span>
      {TRENDING_CHIPS.map((label) => (
        <a
          class={styles.trendLink}
          href={`/search?q=${encodeURIComponent(label)}`}
          key={label}
        >
          {label}
        </a>
      ))}
    </div>
  );
}

export default function HomeHeroPanel({ dbStats, error }: Props) {
  const indexed = dbStats ? dbStats.linkCount.toLocaleString() : "—";
  const cats = dbStats ? dbStats.categoryCount.toLocaleString() : "—";
  return (
    <div class={styles.panel}>
      {error
        ? (
          <div class="banner error" role="alert">
            <span>{error}</span>
          </div>
        )
        : null}
      <form class="search-wrap" action="/search" method="GET" role="search">
        {SEARCH_GLYPH}
        <input
          type="text"
          name="q"
          placeholder="Search the open web directory…"
          aria-label="Search the directory"
        />
        <button type="submit" class="btn small">Search</button>
      </form>
      <TrendingChips />
      <hr class={styles.divider} />
      <ul class={styles.stats}>
        <StatCell label="Indexed links" value={indexed} />
        <StatCell label="Categories" value={cats} />
      </ul>
    </div>
  );
}
