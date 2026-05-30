import { page } from "fresh";
import { define } from "../utils.ts";
import Eyebrow from "../components/common/Eyebrow/Eyebrow.tsx";
import SectionHead from "../components/common/SectionHead/SectionHead.tsx";
import CategoryRow from "../components/common/CategoryRow/CategoryRow.tsx";
import styles from "./about.module.css";

interface Principle {
  num: string;
  name: string;
  description: string;
}

interface ArchCell {
  label: string;
  value: string;
  border: boolean;
}

const PRINCIPLES: Principle[] = [
  {
    num: "01",
    name: "Editor-vetted by default",
    description:
      "Every link reviewed by a human steward before landing in the index.",
  },
  {
    num: "02",
    name: "Hierarchical, not algorithmic",
    description:
      "Sixteen ODP-style top-level categories, no scoring, no reordering.",
  },
  {
    num: "03",
    name: "Open and inspectable",
    description:
      "Single static binary, embedded database, all data on disk in plain pages.",
  },
  {
    num: "04",
    name: "Non-extractive",
    description: "No tracking, no sign-up wall to read, no advertising.",
  },
];

const ARCH_CELLS: ArchCell[] = [
  { label: "Language", value: "Zig 0.15", border: true },
  { label: "Storage", value: "16KB pages, B+Tree", border: true },
  { label: "Frontend", value: "Deno Fresh", border: false },
];

export const handler = define.handlers({
  GET(ctx) {
    ctx.state.title = "About";
    return page({});
  },
});

function ArchCard({ cell }: { cell: ArchCell }) {
  return (
    <div class={`${styles.archCell} ${cell.border ? styles.bordered : ""}`}>
      <span class="micro">— {cell.label}</span>
      <div class={`h2 mt-8 ${styles.archValue}`}>{cell.value}</div>
    </div>
  );
}

export default define.page(function AboutPage() {
  return (
    <>
      <section class={`section ${styles.heroSection}`}>
        <div class="container text-center">
          <Eyebrow muted label="About" />
          <h1 class={`display mt-16 ${styles.headline}`}>
            A reference implementation.
          </h1>
          <p class={`lede mt-24 ${styles.lede}`}>
            DMOZSTYLE is a directory of editor-vetted links built on a custom
            Zig database server. The reading experience requires zero
            JavaScript; the index, taxonomy, and search are served from a single
            static binary.
          </p>
        </div>
      </section>

      <section class="section gray">
        <div class="container">
          <SectionHead num="01" topic="Principles" title="Four principles." />
          <ul class="list list-bleed-borders mt-32">
            {PRINCIPLES.map((p) => (
              <CategoryRow
                key={p.num}
                num={p.num}
                href="#"
                name={p.name}
                childrenPreview={[p.description]}
              />
            ))}
          </ul>
        </div>
      </section>

      <section class="section">
        <div class="container">
          <SectionHead num="02" topic="Architecture" title="Built in Zig." />
          <div class={styles.archGrid}>
            {ARCH_CELLS.map((cell) => (
              <ArchCard key={cell.label} cell={cell} />
            ))}
          </div>
        </div>
      </section>

      <section class="section dark">
        <div class="container text-center">
          <SectionHead
            num="03"
            topic="Read more"
            title="Read the architecture notes."
          />
          <div class="row center mt-32">
            <a class="btn invert" href="https://github.com" target="_blank">
              GitHub →
            </a>
          </div>
        </div>
      </section>
    </>
  );
});
