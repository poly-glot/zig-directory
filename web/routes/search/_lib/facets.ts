import type { Crumb, Link } from "../../../lib/dmoz-client.ts";
import { formatCategoryName } from "../../../lib/format.ts";
import { buildHref } from "./queryParams.ts";
import type { FacetItem, Sort, YearItem } from "./types.ts";

const FACET_LIMIT = 100;

const MAX_PATH_SEGMENTS = 4;

/**
 * Build a breadcrumb-style label from a category's root→leaf chain (e.g.
 * `Arts › Visual_Arts › Drawing`). The canonical root ("Top") is skipped so
 * callers don't see it in the UI. Long chains are truncated with `…` in the
 * middle so deep DMOZ paths stay readable in the sidebar.
 */
export function buildPathLabel(
  id: number,
  chains: Map<number, Crumb[]>,
): string {
  const names = (chains.get(id) ?? []).map((c) => formatCategoryName(c.name));
  if (names.length > 0 && names[0].toLowerCase() === "top") names.shift();
  if (names.length <= MAX_PATH_SEGMENTS) return names.join(" › ");
  // Keep the first (taxonomy context) and the last 2 (distinguishing
  // leaves — many DMOZ subtrees share a deep ancestor but diverge near
  // the bottom).
  return [
    names[0],
    "…",
    names[names.length - 2],
    names[names.length - 1],
  ].join(" › ");
}

export function applyFilters(links: Link[], cat: number, year: number): Link[] {
  return links.filter((l) => {
    if (cat > 0 && l.categoryId !== cat) return false;
    if (year > 0) {
      if (l.createdAt.getTime() <= 0) return false;
      if (l.createdAt.getFullYear() !== year) return false;
    }
    return true;
  });
}

export function applySort(links: Link[], sort: Sort): Link[] {
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

export function computeCategoryFacet(
  links: Link[],
  chains: Map<number, Crumb[]>,
  q: string,
  sort: Sort,
  year: number,
  activeCat: number,
): FacetItem[] {
  const counts = new Map<number, number>();
  for (const l of links) {
    counts.set(l.categoryId, (counts.get(l.categoryId) ?? 0) + 1);
  }
  const items: FacetItem[] = [];
  for (const [id, count] of counts) {
    const chain = chains.get(id);
    if (!chain || chain.length === 0) continue;
    items.push({
      id,
      label: buildPathLabel(id, chains) ||
        formatCategoryName(chain[chain.length - 1].name),
      count,
      href: buildHref({ q, sort }, { cat: id, year }),
      active: id === activeCat,
    });
  }
  items.sort((a, b) => b.count - a.count || a.label.localeCompare(b.label));
  return items.slice(0, FACET_LIMIT);
}

export function computeYearFacet(
  links: Link[],
  q: string,
  sort: Sort,
  cat: number,
  activeYear: number,
): YearItem[] {
  const counts = new Map<number, number>();
  for (const l of links) {
    if (l.createdAt.getTime() <= 0) continue;
    counts.set(
      l.createdAt.getFullYear(),
      (counts.get(l.createdAt.getFullYear()) ?? 0) + 1,
    );
  }
  const items: YearItem[] = [];
  for (const [year, count] of counts) {
    items.push({
      year,
      count,
      href: buildHref({ q, sort }, { cat, year }),
      active: year === activeYear,
    });
  }
  items.sort((a, b) => b.year - a.year);
  return items;
}
