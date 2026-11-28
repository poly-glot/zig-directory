import { assertEquals, assertStringIncludes } from "jsr:@std/assert@^1";
import { afterCursor, errorResponse, pageSize } from "./api.ts";
import { handler as queryHandler } from "../links/query.ts";
import { handler as searchHandler } from "../search.ts";
import {
  DmozError,
  SEARCH_QUERY_MAX_CHARS,
  Status,
  SubStatus,
} from "../../../../lib/dmoz-client.ts";
import { handler as categoryChildrenHandler } from "../../category-children.ts";
import { handler as categoryLinksHandler } from "../categories/[id]/links.ts";
import { call } from "./route_call.ts";

Deno.test("limit and cursor reject out-of-range values instead of clamping them", () => {
  assertEquals(pageSize(null), 20);
  assertEquals(pageSize("50"), 50);
  assertEquals(pageSize("500"), undefined);
  assertEquals(pageSize("0"), undefined);
  assertEquals(pageSize("-1"), undefined);
  assertEquals(pageSize("12abc"), undefined);

  assertEquals(afterCursor(null), 0);
  assertEquals(afterCursor("12792"), 12792);
  assertEquals(afterCursor("-5"), undefined);
  assertEquals(afterCursor("1e3"), undefined);
});

Deno.test("links/query rejects a malformed cursor instead of restarting at page one", async () => {
  const { status } = await call(queryHandler, "/q?words=music&after=-5");

  assertEquals(status, 400);
});

Deno.test("api search rejects an out-of-range limit instead of clamping it", async () => {
  const { status, body } = await call(
    searchHandler,
    `/s?q=${"x".repeat(SEARCH_QUERY_MAX_CHARS)}&limit=500`,
  );

  assertEquals(status, 400);
  assertEquals(body.error?.startsWith("limit must be"), true);
});

Deno.test("category links refuse an id that is not a plain integer before asking the backend", async () => {
  for (const id of ["1e3", "0x10", "1.5", "5abc"]) {
    const { status, body } = await call(categoryLinksHandler, "/c", { id });

    assertEquals(status, 400, id);
    assertEquals(body.error, "invalid category id");
  }
});

Deno.test("category links reject a bad limit or cursor instead of clamping", async () => {
  const limit = await call(categoryLinksHandler, "/c?limit=500", { id: "5" });
  const cursor = await call(categoryLinksHandler, "/c?after_id=-5", {
    id: "5",
  });

  assertEquals(limit.status, 400);
  assertEquals(cursor.status, 400);
  assertEquals(
    cursor.body.error,
    "after_id must be a whole number of 0 or more",
  );
});

Deno.test("category-children does not echo the backend address on failure", async () => {
  Deno.env.set("DMOZDB_HOST", "127.0.0.1");
  Deno.env.set("DMOZDB_PORT", "1");
  const quiet = console.error;
  console.error = () => {};
  try {
    const { getClient } = await import("../../../../lib/dmoz-client.ts");
    const { status, body } = await call(
      categoryChildrenHandler,
      "/c?parentId=5",
    );
    getClient().close();

    assertEquals(status, 500);
    assertEquals(JSON.stringify(body).includes("127.0.0.1"), false);
    assertEquals(JSON.stringify(body).includes("DmozError"), false);
  } finally {
    console.error = quiet;
  }
});

Deno.test("a too-broad refusal answers 400 with a message that says how to narrow it", async () => {
  const refused = new DmozError(
    Status.Invalid,
    SubStatus.TooBroad,
    "dmozdb error: invalid / too broad (status=3 sub=12)",
  );
  const response = errorResponse(refused);
  const body = await response.json();

  assertEquals(response.status, 400);
  assertStringIncludes(body.error, "too broad");
  assertStringIncludes(body.error, "Narrow it");
});
