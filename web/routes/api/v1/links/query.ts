import { define } from "../../../../utils.ts";
import {
  COUNTRY_EDGES,
  type CountryEdge,
  getClient,
  type LinkQueryGroupBy,
  MAX_ENTITY_NAME_BYTES,
  QUERY_LINKS_MAX_ROWS,
} from "../../../../lib/dmoz-client.ts";
import { type Religion, RELIGIONS } from "../../../../lib/dmoz-protocol.gen.ts";
import { categoryPath } from "../../../../lib/format.ts";
import {
  categoryNotFound,
  errorResponse,
  linkJson,
  nonNegativeInt,
} from "../_lib/api.ts";

const GROUP_BY: readonly LinkQueryGroupBy[] = [
  "none",
  "domain",
  "site",
  "host",
  "branch",
  "country",
  "religion",
  "person",
  "org",
];
const WORD_MATCHES = ["any", "all"] as const;
const COUNTRY_CODE = /^[A-Za-z]{2}$/;
const DEFAULT_GROUPS = 10;
const DEFAULT_LIMIT = 20;

function oneOf<T extends string>(
  raw: string | null,
  allowed: readonly T[],
  fallback: T,
): T | undefined {
  if (raw === null || raw === "") return fallback;
  return allowed.find((value) => value === raw);
}

function listOf<T extends string>(
  raw: string | null,
  allowed: readonly T[],
  fallback: readonly T[],
): T[] | undefined {
  if (raw === null || raw.trim() === "") return [...fallback];
  const values = raw.split(",").map((value) => value.trim());
  const known = values.map((value) => allowed.find((a) => a === value));
  return known.every((value) => value !== undefined) ? known as T[] : undefined;
}

function rows(raw: string | null, fallback: number): number | undefined {
  if (raw === null || raw === "") return fallback;
  const n = Number(raw);
  const valid = Number.isInteger(n) && n >= 0 && n <= QUERY_LINKS_MAX_ROWS;
  return valid ? n : undefined;
}

function badRequest(error: string): Response {
  return Response.json({ error }, { status: 400 });
}

export const handler = define.handlers({
  async GET(ctx) {
    const params = ctx.url.searchParams;
    const country = (params.get("country") ?? "").trim();
    const groupBy = oneOf(params.get("group"), GROUP_BY, "none");
    const via = listOf<CountryEdge>(
      params.get("via"),
      COUNTRY_EDGES,
      COUNTRY_EDGES,
    );
    const religions = listOf<Religion>(params.get("religion"), RELIGIONS, []);
    const entity = (params.get("entity") ?? "").trim();
    const match = oneOf(params.get("match"), WORD_MATCHES, "any");
    const groupLimit = rows(params.get("groups"), DEFAULT_GROUPS);
    const limit = rows(params.get("limit"), DEFAULT_LIMIT);

    if (country !== "" && !COUNTRY_CODE.test(country)) {
      return badRequest("country must be a two-letter ISO 3166 code");
    }
    if (!groupBy) return badRequest(`group must be one of ${GROUP_BY}`);
    if (!via) return badRequest(`via must list some of ${COUNTRY_EDGES}`);
    if (!religions) {
      return badRequest(`religion must list some of ${RELIGIONS}`);
    }
    if (new TextEncoder().encode(entity).length > MAX_ENTITY_NAME_BYTES) {
      return badRequest(
        `entity must be at most ${MAX_ENTITY_NAME_BYTES} bytes`,
      );
    }
    if (!match) return badRequest(`match must be one of ${WORD_MATCHES}`);
    if (groupLimit === undefined || limit === undefined) {
      return badRequest(
        `groups and limit must be 0 to ${QUERY_LINKS_MAX_ROWS}`,
      );
    }

    try {
      const client = getClient();
      const path = (params.get("category") ?? "").trim();
      let categoryId = 0;
      if (path !== "") {
        const browsed = await client.browsePathIfFound(path);
        if (!browsed) return categoryNotFound(path);
        categoryId = browsed.category.id;
      }

      const result = await client.queryLinks({
        categoryId,
        domain: (params.get("domain") ?? "").trim(),
        country: country.toUpperCase(),
        via,
        hostedOnly: ["1", "true"].includes(params.get("hosted") ?? ""),
        subdomainOnly: ["1", "true"].includes(params.get("subdomain") ?? ""),
        words: (params.get("words") ?? "").trim(),
        allWords: match === "all",
        religions,
        entity,
        groupBy,
        groupLimit,
        limit,
        afterId: nonNegativeInt(params.get("after")),
      });
      if (!result.ready) {
        return Response.json(
          { error: "link facts are still loading, retry shortly" },
          { status: 503 },
        );
      }

      const categoryIds = new Set([
        ...result.links.map((l) => l.categoryId),
        ...result.groups.map((g) => g.categoryId).filter((id) => id > 0),
      ]);
      const chains = await client.breadcrumbsByIds([...categoryIds]);
      const pathOf = (id: number) => categoryPath(chains.get(id) ?? []);

      return Response.json({
        total: result.total,
        sites: result.sites,
        hosts: result.hosts,
        domains: result.domains,
        groups: result.groups.map((g) => ({
          key: g.categoryId > 0 ? pathOf(g.categoryId) : g.label,
          links: g.links,
          sites: g.sites,
        })),
        links: result.links.map((l) => ({
          ...linkJson(l),
          categoryPath: pathOf(l.categoryId),
          site: l.site,
          countries: {
            cctld: l.cctldCountry || null,
            category: l.categoryCountry || null,
            entities: l.entityCountries,
          },
          religions: l.religions,
        })),
        nextAfterId: result.nextAfterId,
      });
    } catch (e) {
      return errorResponse(e);
    }
  },
});
