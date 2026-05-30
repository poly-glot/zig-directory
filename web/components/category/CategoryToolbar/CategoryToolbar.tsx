import TagChipRow from "../../common/TagChipRow/TagChipRow.tsx";
import DensityToggle from "../../../islands/DensityToggle.tsx";
import styles from "./CategoryToolbar.module.css";

export type Sort = "relevance" | "recent" | "az";

export interface TagChip {
  tag: string;
  count: number;
  href: string;
  active: boolean;
}

interface Props {
  currentPath: string;
  page: number;
  sort: Sort;
  activeTag: string;
  tagChips: TagChip[];
  clearTagHref: string;
  rawCount: number;
  filteredCount: number;
}

function summaryText(activeTag: string, raw: number, filtered: number): string {
  if (activeTag) {
    return `${filtered} of ${raw} on this page match "${activeTag}"`;
  }
  return `Showing ${raw} on this page`;
}

function SortForm(
  { currentPath, page, sort, activeTag }: {
    currentPath: string;
    page: number;
    sort: Sort;
    activeTag: string;
  },
) {
  return (
    <form
      method="GET"
      action={`/category/${currentPath}`}
      class="row gap-8"
    >
      {page > 1
        ? <input type="hidden" name="page" value={String(page)} />
        : null}
      {activeTag ? <input type="hidden" name="tag" value={activeTag} /> : null}
      <label class={styles.sortLabel} for="sort">Sort</label>
      <select
        id="sort"
        name="sort"
        class={`select ${styles.sortSelect}`}
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

export default function CategoryToolbar(props: Props) {
  const {
    currentPath,
    page,
    sort,
    activeTag,
    tagChips,
    clearTagHref,
    rawCount,
    filteredCount,
  } = props;
  return (
    <div class={`${styles.toolbar} mt-32`}>
      <div class="row between flex-wrap gap-16">
        <div class={`micro ${styles.summary}`}>
          {summaryText(activeTag, rawCount, filteredCount)}
        </div>
        <div class="row gap-16 flex-wrap">
          <DensityToggle />
          <SortForm
            currentPath={currentPath}
            page={page}
            sort={sort}
            activeTag={activeTag}
          />
        </div>
      </div>
      <TagChipRow
        chips={tagChips}
        clearHref={clearTagHref}
        hasActiveTag={activeTag.length > 0}
      />
    </div>
  );
}
