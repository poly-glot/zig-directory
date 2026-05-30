import type { DbStats } from "../../../lib/dmoz-client.ts";
import SectionHead from "../../common/SectionHead/SectionHead.tsx";
import KpiStrip from "../../common/KpiStrip/KpiStrip.tsx";

interface Props {
  dbStats: DbStats;
}

const ARROW = (
  <span class="arrow" aria-hidden="true">
    <svg
      width="10"
      height="8"
      viewBox="0 0 10 8"
      fill="none"
      stroke="currentColor"
      stroke-width="1.5"
    >
      <path d="M1 4h8M6 1l3 3-3 3" />
    </svg>
  </span>
);

function formatHitRate(stats: DbStats): string {
  const denom = stats.cacheHits + stats.cacheMisses;
  if (denom <= 0) return "—";
  const pct = (stats.cacheHits / denom) * 100;
  return `${pct.toFixed(1)}%`;
}

export default function HomeStatsSection({ dbStats }: Props) {
  const cells = [
    { label: "Indexed links", value: dbStats.linkCount.toLocaleString() },
    { label: "Categories", value: dbStats.categoryCount.toLocaleString() },
    { label: "Cache pages", value: dbStats.pageCount.toLocaleString() },
    { label: "Cache hit rate", value: formatHitRate(dbStats) },
  ];
  return (
    <section class="section dark">
      <div class="container">
        <SectionHead
          num="03"
          topic="Built in Zig"
          title={
            <>
              An embedded database.<br />A microsecond hot path.
            </>
          }
          lede="DMOZSTYLE runs against a custom Zig server with a binary protocol. Numbers below come from the live instance."
        />
        <KpiStrip cells={cells} />
        <div class="text-center mt-48">
          <a class="btn invert" href="/about">
            Read the architecture notes {ARROW}
          </a>
        </div>
      </div>
    </section>
  );
}
