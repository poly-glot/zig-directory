// Query-param parsing/building for the /category route. Lives next to the
// route so the URL contract stays in one place.

import type {
  Sort,
  TagChip,
} from "../../../components/category/CategoryToolbar/CategoryToolbar.tsx";

export type { Sort, TagChip };

export const PAGE_SIZE = 50;
export const OFFSET_CAP = 5000;
export const MAX_PAGES = Math.floor(OFFSET_CAP / PAGE_SIZE) + 1;
export const TAG_LIMIT = 12;

export function parseSort(raw: string | null): Sort {
  if (raw === "recent" || raw === "az") return raw;
  return "relevance";
}

export function buildToolbarHref(
  path: string,
  page: number,
  sort: Sort,
  tag: string,
): string {
  const params = new URLSearchParams();
  if (page > 1) params.set("page", String(page));
  if (sort !== "relevance") params.set("sort", sort);
  if (tag) params.set("tag", tag);
  const qs = params.toString();
  return qs ? `/category/${path}?${qs}` : `/category/${path}`;
}
