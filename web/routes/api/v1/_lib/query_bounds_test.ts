import { assertEquals } from "jsr:@std/assert@^1";
import { call } from "./route_call.ts";
import { handler as queryHandler } from "../links/query.ts";
import { handler as searchHandler } from "../search.ts";
import { SEARCH_QUERY_MAX_CHARS } from "../../../../lib/dmoz-client.ts";

Deno.test("links/query refuses a request with no recognised filter", async () => {
  for (const path of ["/q", "/q?limit=5", "/q?category=&words=%20&named="]) {
    const { status, body } = await call(queryHandler, path);

    assertEquals(status, 400);
    assertEquals(body.error?.startsWith("give at least one of"), true);
  }
});

Deno.test("links/query names every unknown parameter instead of running an unfiltered scan", async () => {
  const { status, body } = await call(
    queryHandler,
    "/q?categroy=arts&wrods=x&words=music",
  );

  assertEquals(status, 400);
  assertEquals(body.error?.includes("categroy, wrods"), true);
});

Deno.test("links/query bounds words by the search query cap", async () => {
  const words = "a".repeat(SEARCH_QUERY_MAX_CHARS + 1);
  const { status, body } = await call(queryHandler, `/q?words=${words}`);

  assertEquals(status, 400);
  assertEquals(body.error?.includes(String(SEARCH_QUERY_MAX_CHARS)), true);
});

Deno.test("api search answers 400 for a query over the cap and never reaches the backend", async () => {
  const { status, body } = await call(
    searchHandler,
    `/s?q=${"x".repeat(SEARCH_QUERY_MAX_CHARS + 1)}`,
  );

  assertEquals(status, 400);
  assertEquals(body.error?.includes(String(SEARCH_QUERY_MAX_CHARS)), true);
});
