import { assertEquals } from "jsr:@std/assert@^1";
import type { State } from "../utils.ts";
import { PublicApp } from "./public-app.ts";
import { securityHeaders } from "./security-headers.ts";

Deno.test("malformed percent-encoding in a dynamic path is a 400, not a 500", async () => {
  const app = new PublicApp<State>()
    .use(securityHeaders)
    .get("/category/:path*", (ctx) => new Response(ctx.params.path));

  const bad = await app.handler()(
    new Request("http://dmoz.test/category/%FF"),
  );
  assertEquals(bad.status, 400);
  assertEquals(bad.headers.get("x-content-type-options"), "nosniff");
  await bad.body?.cancel();

  const good = await app.handler()(
    new Request("http://dmoz.test/category/arts/caf%C3%A9"),
  );
  assertEquals(await good.text(), "arts/café");
});
