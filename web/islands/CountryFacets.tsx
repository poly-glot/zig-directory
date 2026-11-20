import { useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import styles from "./CountryFacets.module.css";

interface Props {
  words: string[];
}

interface CountryGroup {
  key: string;
  links: number;
}

const GROUPS = 6;
const GROUPS_WORTH_SHOWING = 2;
const REGION = new Intl.DisplayNames(["en"], { type: "region" });

function facetsUrl(words: readonly string[]): string {
  const params = new URLSearchParams({
    words: words.join(" "),
    match: "all",
    budget: "1",
    group: "country",
    groups: String(GROUPS),
    limit: "0",
  });
  return `/api/v1/links/query?${params}`;
}

function countryHref(code: string, words: readonly string[]): string {
  const query = [`country:${code.toLowerCase()}`, ...words].join(" ");
  return `/search?${new URLSearchParams({ q: query })}`;
}

export default function CountryFacets({ words }: Props) {
  const groups = useSignal<CountryGroup[]>([]);

  useEffect(() => {
    if (words.length === 0) return;

    const abort = new AbortController();
    fetch(facetsUrl(words), { signal: abort.signal })
      .then((response) => response.ok ? response.json() : { groups: [] })
      .then((found: { groups: CountryGroup[] }) => {
        groups.value = found.groups;
      })
      .catch(() => {});
    return () => abort.abort();
  }, [words.join(" ")]);

  if (groups.value.length < GROUPS_WORTH_SHOWING) return null;

  return (
    <div class={styles.row} data-facet="country">
      <span class="micro">By country</span>
      {groups.value.map((group) => (
        <a
          key={group.key}
          class={styles.chip}
          href={countryHref(group.key, words)}
        >
          {REGION.of(group.key) ?? group.key}{" "}
          <span class={styles.count}>
            {group.links.toLocaleString("en-US")}
          </span>
        </a>
      ))}
    </div>
  );
}
