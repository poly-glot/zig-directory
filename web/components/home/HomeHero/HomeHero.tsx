import type { DbStats } from "../../../lib/dmoz-client.ts";
import Eyebrow from "../../common/Eyebrow/Eyebrow.tsx";
import HomeHeroPanel from "../HomeHeroPanel/HomeHeroPanel.tsx";
import styles from "./HomeHero.module.css";

interface Props {
  dbStats: DbStats | null;
  error?: string;
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

export default function HomeHero({ dbStats, error }: Props) {
  return (
    <section class={`${styles.hero} hero`}>
      <div class="container">
        <div class={styles.grid}>
          <div>
            <Eyebrow muted label="A reference implementation" />
            <h1 class={`display ${styles.title}`}>
              A hand-curated<br />directory of<br />the open web.
            </h1>
            <p class={`lede ${styles.lede}`}>
              Built in Zig with an embedded database. Hand-curated categories,
              editor-vetted links, and zero algorithmic ranking. Submit a site,
              browse by topic, or search the index.
            </p>
            <div class={styles.actions}>
              <a class="btn" href="/search">Browse the index {ARROW}</a>
              <a class="btn link" href="/about">How it works →</a>
            </div>
          </div>
          <div>
            <HomeHeroPanel dbStats={dbStats} error={error} />
          </div>
        </div>
      </div>
    </section>
  );
}
