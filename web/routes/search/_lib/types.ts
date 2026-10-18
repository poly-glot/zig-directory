import type { LinkQueryResult } from "../../../lib/dmoz-client.ts";

export type Sort = "relevance" | "recent" | "az";

export interface Chip {
  label: string;
  href: string;
}

export interface Relaxation extends Chip {
  links: number;
}

export type LinkCounts = Pick<
  LinkQueryResult,
  "total" | "sites" | "hosts" | "domains"
>;

export interface FacetItem {
  id: number;
  label: string;
  count: number;
  href: string;
  active: boolean;
}

export interface YearItem {
  year: number;
  count: number;
  href: string;
  active: boolean;
}

export interface Facets {
  categories: FacetItem[];
  years: YearItem[];
  clearCategoryHref: string;
  clearYearHref: string;
  hasCategoryFilter: boolean;
  hasYearFilter: boolean;
}
