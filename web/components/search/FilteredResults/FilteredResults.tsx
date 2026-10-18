import type { Link } from "../../../lib/dmoz-client.ts";
import type {
  Chip,
  LinkCounts,
  Relaxation,
} from "../../../routes/search/_lib/types.ts";
import SectionHead from "../../common/SectionHead/SectionHead.tsx";
import ResultArticle from "../ResultArticle/ResultArticle.tsx";
import styles from "./FilteredResults.module.css";

interface Props {
  chips: Chip[];
  plainHref: string;
  relaxations: Relaxation[];
  links: Link[];
  tokens: string[];
  nextHref?: string;
}

function counted(n: number, one: string, many: string) {
  return (
    <>
      <strong>{n.toLocaleString("en-US")}</strong> {n === 1 ? one : many}
    </>
  );
}

export function FilteredCount({ counts }: { counts: LinkCounts }) {
  return (
    <>
      {counted(counts.total, "link", "links")} on{" "}
      {counted(counts.sites, "site", "sites")} ·{" "}
      {counted(counts.hosts, "host", "hosts")} ·{" "}
      {counted(counts.domains, "domain", "domains")}
    </>
  );
}

function Targets({ chips, plainHref }: { chips: Chip[]; plainHref: string }) {
  return (
    <div class={styles.targets}>
      {chips.map((chip) => (
        <a
          key={chip.href}
          class={styles.chip}
          href={chip.href}
          aria-label={`Remove ${chip.label}`}
        >
          {chip.label} <span aria-hidden="true">×</span>
        </a>
      ))}
      <a class={`under ${styles.plain}`} href={plainHref}>
        Search the words instead
      </a>
    </div>
  );
}

function NoMatch({ relaxations }: { relaxations: Relaxation[] }) {
  return (
    <div class="banner">
      <div>
        No links match all of these.
        {relaxations.length > 0
          ? (
            <ul class={styles.relaxations}>
              {relaxations.map((r) => (
                <li key={r.href}>
                  Without “{r.label}”:{" "}
                  <a href={r.href}>
                    {r.links.toLocaleString("en-US")}{" "}
                    {r.links === 1 ? "link" : "links"}
                  </a>
                </li>
              ))}
            </ul>
          )
          : null}
      </div>
    </div>
  );
}

export default function FilteredResults(
  { chips, plainHref, relaxations, links, tokens, nextHref }: Props,
) {
  return (
    <section class="section">
      <div class="container">
        <div class="mb-24">
          <SectionHead num="01" topic="Listings" title="Matching links." />
        </div>
        <Targets chips={chips} plainHref={plainHref} />
        {links.length === 0
          ? <NoMatch relaxations={relaxations} />
          : (
            <div class="cards fluid">
              {links.map((l) => (
                <ResultArticle key={l.id} link={l} tokens={tokens} />
              ))}
            </div>
          )}
        {nextHref
          ? (
            <div class="mt-32">
              <a class="btn" href={nextHref}>Next page</a>
            </div>
          )
          : null}
      </div>
    </section>
  );
}
