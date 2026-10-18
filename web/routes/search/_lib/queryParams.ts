import type { Sort } from "./types.ts";

export function parseSort(raw: string | null): Sort {
  if (raw === "recent" || raw === "az") return raw;
  return "relevance";
}

export function parsePositiveInt(raw: string | null): number {
  if (!raw) return 0;
  const n = parseInt(raw, 10);
  return Number.isFinite(n) && n > 0 ? n : 0;
}

interface BuildHrefBase {
  q: string;
  sort: Sort;
}

interface BuildHrefOverride {
  cat?: number | null;
  year?: number | null;
}

export function searchHref(params: Record<string, string>): string {
  const qs = new URLSearchParams(params).toString();
  return qs ? `/search?${qs}` : "/search";
}

export function buildHref(
  base: BuildHrefBase,
  override: BuildHrefOverride,
): string {
  const params: Record<string, string> = {};
  if (base.q) params.q = base.q;
  if (base.sort !== "relevance") params.sort = base.sort;
  if (override.cat && override.cat > 0) params.cat = String(override.cat);
  if (override.year && override.year > 0) params.year = String(override.year);
  return searchHref(params);
}
