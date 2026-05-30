export type Sort = "relevance" | "recent" | "az";

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
