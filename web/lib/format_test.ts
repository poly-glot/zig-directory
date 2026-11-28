import { assertEquals } from "jsr:@std/assert@^1";
import { listingsLede } from "./format.ts";

Deno.test("the listings lede counts editor-approved links", () => {
  assertEquals(
    listingsLede(2, 50, 1234, 50),
    "Showing 51–100 of 1,234 editor-approved links.",
  );
});
