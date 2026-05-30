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

export function buildHref(
  base: BuildHrefBase,
  override: BuildHrefOverride,
): string {
  const params = new URLSearchParams();
  if (base.q) params.set("q", base.q);
  if (base.sort !== "relevance") params.set("sort", base.sort);
  if (override.cat && override.cat > 0) params.set("cat", String(override.cat));
  if (override.year && override.year > 0) {
    params.set("year", String(override.year));
  }
  const qs = params.toString();
  return qs ? `/search?${qs}` : "/search";
}
