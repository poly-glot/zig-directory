import { MAX_PAGE_SIZE } from "./api.ts";

const category = {
  type: "object",
  required: [
    "id",
    "path",
    "name",
    "slug",
    "description",
    "linkCount",
    "childCount",
    "linkCountSubtree",
    "childCountSubtree",
  ],
  properties: {
    id: { type: "integer" },
    path: {
      type: "string",
      description:
        "Slug path usable as the `path` argument of browse_category.",
    },
    name: { type: "string" },
    slug: { type: "string" },
    description: { type: "string" },
    linkCount: { type: "integer", description: "Links filed directly here." },
    childCount: { type: "integer" },
    linkCountSubtree: {
      type: "integer",
      description: "Links anywhere beneath this category, inclusive.",
    },
    childCountSubtree: { type: "integer" },
  },
} as const;

const link = {
  type: "object",
  required: [
    "id",
    "categoryId",
    "url",
    "title",
    "description",
    "status",
    "tags",
    "language",
    "region",
    "createdAt",
  ],
  properties: {
    id: { type: "integer" },
    categoryId: { type: "integer" },
    url: { type: "string" },
    title: { type: "string" },
    description: { type: "string" },
    status: {
      type: "string",
      enum: ["pending", "approved", "rejected", "unknown"],
    },
    tags: { type: "string" },
    language: { type: "string" },
    region: { type: "string" },
    createdAt: { type: "string", format: "date-time" },
  },
} as const;

const errorSchema = {
  type: "object",
  required: ["error"],
  properties: { error: { type: "string" } },
} as const;

const jsonContent = (schema: unknown) => ({
  content: { "application/json": { schema } },
});

const errorResponses = {
  "400": { description: "Invalid arguments", ...jsonContent(errorSchema) },
  "404": { description: "No such category", ...jsonContent(errorSchema) },
  "503": { description: "Directory unavailable", ...jsonContent(errorSchema) },
};

const limitParam = {
  name: "limit",
  in: "query",
  required: false,
  description: `Page size, 1 to ${MAX_PAGE_SIZE}. Larger values are clamped.`,
  schema: { type: "integer", minimum: 1, maximum: MAX_PAGE_SIZE },
};

export const openapi = {
  openapi: "3.1.0",
  info: {
    title: "dmozdb directory",
    version: "1.0.0",
    description:
      "Read access to a hand-curated web directory of approved links organised as a category tree.",
  },
  paths: {
    "/api/v1/browse": {
      get: {
        operationId: "browse_category",
        summary:
          "Browse one category: its ancestors, child categories and subtree size",
        description:
          "Returns a category with its breadcrumb ancestors and immediate child categories. Call with an empty path to list the top-level categories, then follow the `path` of a child to descend. Returns no links; use list_links_in_subtree for those.",
        parameters: [
          {
            name: "path",
            in: "query",
            required: false,
            description:
              "Slug path such as `arts` or `arts/music`, taken from the `path` field of an earlier result. Empty lists the top-level categories.",
            schema: { type: "string" },
          },
        ],
        responses: {
          "200": {
            description: "The category, its ancestors and its children",
            ...jsonContent({
              type: "object",
              required: [
                "category",
                "ancestors",
                "children",
                "totalLinksInSubtree",
              ],
              properties: {
                category: { anyOf: [category, { type: "null" }] },
                ancestors: { type: "array", items: category },
                children: { type: "array", items: category },
                totalLinksInSubtree: { type: "integer" },
              },
            }),
          },
          ...errorResponses,
        },
      },
    },
    "/api/v1/categories/{id}/links": {
      get: {
        operationId: "list_links_in_subtree",
        summary: "List approved links in a category and everything beneath it",
        description:
          "One page of approved links from the whole subtree of a category, ordered by link id. Pass the returned `nextAfterId` back as `after_id` for the next page; a `nextAfterId` of 0 means the last page.",
        parameters: [
          {
            name: "id",
            in: "path",
            required: true,
            description:
              "Category id, from the `id` field of a browse or search result.",
            schema: { type: "integer" },
          },
          {
            name: "after_id",
            in: "query",
            required: false,
            description:
              "Cursor: return links with an id greater than this. Omit for the first page.",
            schema: { type: "integer", minimum: 0 },
          },
          limitParam,
        ],
        responses: {
          "200": {
            description: "A page of links plus the cursor for the next page",
            ...jsonContent({
              type: "object",
              required: ["links", "total", "nextAfterId"],
              properties: {
                links: { type: "array", items: link },
                total: {
                  type: "integer",
                  description:
                    "Total links in the subtree, not just this page.",
                },
                nextAfterId: { type: "integer" },
              },
            }),
          },
          ...errorResponses,
        },
      },
    },
    "/api/v1/search": {
      get: {
        operationId: "search_directory",
        summary: "Search the directory for categories and approved links",
        description:
          "Substring search over category names and over link titles, URLs and descriptions. Use it to find an entry point when the category path is unknown.",
        parameters: [
          {
            name: "q",
            in: "query",
            required: true,
            description: "Search text, at least 2 characters.",
            schema: { type: "string", minLength: 2 },
          },
          {
            name: "scope",
            in: "query",
            required: false,
            description:
              "Restrict results to categories or to links. Defaults to both.",
            schema: { type: "string", enum: ["both", "links", "categories"] },
          },
          limitParam,
        ],
        responses: {
          "200": {
            description: "Matching categories and links",
            ...jsonContent({
              type: "object",
              required: ["query", "categories", "links"],
              properties: {
                query: { type: "string" },
                categories: { type: "array", items: category },
                links: {
                  type: "array",
                  items: {
                    allOf: [link],
                    type: "object",
                    required: ["categoryPath", "matchedField"],
                    properties: {
                      categoryPath: {
                        type: "string",
                        description:
                          "Slug path of the category this link is filed in.",
                      },
                      matchedField: {
                        type: "string",
                        enum: ["title", "url", "description"],
                      },
                    },
                  },
                },
              },
            }),
          },
          ...errorResponses,
        },
      },
    },
  },
} as const;
