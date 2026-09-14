import { assert, assertEquals } from "jsr:@std/assert@^1";
import { openapi } from "./openapi.ts";

const ROUTES_DIR = new URL("../../../", import.meta.url);

const routeFileFor = (specPath: string) =>
  new URL(`.${specPath.replace(/\{(\w+)\}/g, "[$1]")}.ts`, ROUTES_DIR);

Deno.test("every documented path has a route file", async () => {
  for (const specPath of Object.keys(openapi.paths)) {
    const file = routeFileFor(specPath);
    const stat = await Deno.stat(file).catch(() => null);
    assert(stat?.isFile, `${specPath} has no route file at ${file.pathname}`);
  }
});

Deno.test("operation ids are unique so tool names cannot collide", () => {
  const ids = Object.values(openapi.paths).map((p) => p.get.operationId);
  assertEquals(new Set(ids).size, ids.length);
});
