import { parseTags } from "../../../lib/format.ts";
import {
  buildToolbarHref,
  type Sort,
  TAG_LIMIT,
  type TagChip,
} from "./queryParams.ts";
import type { LinkWithCategory } from "../../../components/category/ListingsSection/ListingsSection.tsx";

export function applySort(
  links: LinkWithCategory[],
  sort: Sort,
): LinkWithCategory[] {
  if (sort === "relevance") return links;
  const out = [...links];
  if (sort === "recent") {
    out.sort((a, b) => b.createdAt.getTime() - a.createdAt.getTime());
  } else {
    out.sort((a, b) =>
      a.title.toLowerCase().localeCompare(b.title.toLowerCase())
    );
  }
  return out;
}

export function applyTagFilter(
  links: LinkWithCategory[],
  tag: string,
): LinkWithCategory[] {
  if (!tag) return links;
  const lc = tag.toLowerCase();
  return links.filter((l) =>
    parseTags(l.tags).some((t) => t.toLowerCase() === lc)
  );
}

export function computeTagChips(
  rawLinks: LinkWithCategory[],
  path: string,
  page: number,
  sort: Sort,
  activeTag: string,
): TagChip[] {
  const counts = new Map<string, number>();
  for (const l of rawLinks) {
    for (const t of parseTags(l.tags)) {
      counts.set(t, (counts.get(t) ?? 0) + 1);
    }
  }
  const chips: TagChip[] = [];
  for (const [tag, count] of counts) {
    chips.push({
      tag,
      count,
      href: buildToolbarHref(path, page, sort, tag),
      active: tag.toLowerCase() === activeTag.toLowerCase(),
    });
  }
  chips.sort((a, b) => b.count - a.count || a.tag.localeCompare(b.tag));
  return chips.slice(0, TAG_LIMIT);
}
