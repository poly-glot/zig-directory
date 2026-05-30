import type { Sort } from "../../../routes/search/_lib/types.ts";
import styles from "./SortControl.module.css";

interface Props {
  query: string;
  sort: Sort;
  cat: number;
  year: number;
}

export default function SortControl({ query, sort, cat, year }: Props) {
  return (
    <form
      method="GET"
      action="/search"
      class={`row gap-12 ${styles.form}`}
    >
      <input type="hidden" name="q" value={query} />
      {cat > 0 ? <input type="hidden" name="cat" value={String(cat)} /> : null}
      {year > 0
        ? <input type="hidden" name="year" value={String(year)} />
        : null}
      <label class="micro" for="sort">Sort by</label>
      <select
        id="sort"
        name="sort"
        class={`select ${styles.select}`}
      >
        <option value="relevance" selected={sort === "relevance"}>
          Relevance
        </option>
        <option value="recent" selected={sort === "recent"}>Recent</option>
        <option value="az" selected={sort === "az"}>A–Z</option>
      </select>
      <button type="submit" class="btn small">Apply</button>
    </form>
  );
}
