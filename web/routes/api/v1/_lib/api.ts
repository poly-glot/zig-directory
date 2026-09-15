import {
  type Category,
  DmozError,
  type Link,
  Status,
} from "../../../../lib/dmoz-client.ts";
import { formatCategoryName } from "../../../../lib/format.ts";

export const MAX_PAGE_SIZE = 50;
const DEFAULT_PAGE_SIZE = 20;
const ROOT_SLUG = "top";

const HTTP_STATUS_BY_DMOZ_STATUS: Record<number, number> = {
  [Status.NotFound]: 404,
  [Status.CategoryNotFound]: 404,
  [Status.Invalid]: 400,
};

export function pageSize(raw: string | null): number {
  const n = parseInt(raw ?? "", 10);
  if (!Number.isFinite(n) || n < 1) return DEFAULT_PAGE_SIZE;
  return Math.min(n, MAX_PAGE_SIZE);
}

export function nonNegativeInt(raw: string | null): number {
  const n = parseInt(raw ?? "", 10);
  return Number.isFinite(n) && n >= 0 ? n : 0;
}

export function categoryPath(chain: Array<{ slug: string }>): string {
  const [root, ...rest] = chain;
  const visible = root?.slug === ROOT_SLUG ? rest : chain;
  return visible.map((c) => c.slug).join("/");
}

export function categoryJson(c: Category, path: string) {
  return {
    id: c.id,
    path,
    name: formatCategoryName(c.name),
    slug: c.slug,
    description: c.description,
    linkCount: c.linkCount,
    childCount: c.childCount,
    linkCountSubtree: c.linkCountSubtree,
    childCountSubtree: c.childCountSubtree,
  };
}

export function linkJson(l: Link) {
  return {
    id: l.id,
    categoryId: l.categoryId,
    url: l.url,
    title: l.title,
    description: l.description,
    status: l.status,
    tags: l.tags,
    language: l.language,
    region: l.region,
    createdAt: l.createdAt,
  };
}

export function errorResponse(e: unknown): Response {
  if (e instanceof DmozError) {
    const status = HTTP_STATUS_BY_DMOZ_STATUS[e.status] ?? 502;
    return Response.json({ error: e.message }, { status });
  }
  console.error("api/v1 failed:", e);
  return Response.json({ error: "directory unavailable" }, { status: 503 });
}
