import {
  type Category,
  DmozError,
  isTooBroad,
  type Link,
  Status,
} from "../../../../lib/dmoz-client.ts";
import { formatCategoryName } from "../../../../lib/format.ts";

const MAX_PAGE_SIZE = 50;
const DEFAULT_PAGE_SIZE = 20;

const HTTP_STATUS_BY_DMOZ_STATUS: Record<number, number> = {
  [Status.NotFound]: 404,
  [Status.CategoryNotFound]: 404,
  [Status.Invalid]: 400,
};

function boundedInteger(
  raw: string | null,
  bounds: { fallback: number; min: number; max: number },
): number | undefined {
  if (raw === null || raw === "") return bounds.fallback;
  if (!/^\d+$/.test(raw)) return undefined;

  const n = Number(raw);
  return n >= bounds.min && n <= bounds.max ? n : undefined;
}

export function pageSize(raw: string | null): number | undefined {
  return boundedInteger(raw, {
    fallback: DEFAULT_PAGE_SIZE,
    min: 1,
    max: MAX_PAGE_SIZE,
  });
}

export function afterCursor(raw: string | null): number | undefined {
  return boundedInteger(raw, {
    fallback: 0,
    min: 0,
    max: Number.MAX_SAFE_INTEGER,
  });
}

export function badRequest(error: string): Response {
  return Response.json({ error }, { status: 400 });
}

export const PAGE_SIZE_MESSAGE =
  `limit must be a whole number from 1 to ${MAX_PAGE_SIZE}`;

export function cursorMessage(name: string): string {
  return `${name} must be a whole number of 0 or more`;
}

export function categoryNotFound(path: string): Response {
  return Response.json({ error: `No category at "${path}"` }, {
    status: 404,
  });
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
    linkCountSubtree: c.linkCountSubtreeApproved,
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

const TOO_BROAD_MESSAGE =
  "The question is too broad: a word or filter in it matches too many links. " +
  "Narrow it with rarer words, by requiring every word to match, or by " +
  "adding a category or a country.";

export function errorResponse(e: unknown): Response {
  if (isTooBroad(e)) {
    return Response.json({ error: TOO_BROAD_MESSAGE }, { status: 400 });
  }
  if (e instanceof DmozError) {
    const status = HTTP_STATUS_BY_DMOZ_STATUS[e.status] ?? 502;
    return Response.json({ error: e.message }, { status });
  }
  console.error("api/v1 failed:", e);
  return Response.json({ error: "directory unavailable" }, { status: 503 });
}
