import { assertEquals } from "jsr:@std/assert@^1";
import type { Context } from "fresh";
import type { State } from "../../../utils.ts";
import { handler as middleware } from "../../_middleware.ts";
import { handler as logout } from "../logout.tsx";
import { handler as apiAuth } from "../../api/auth.ts";
import { callHandler, contextFor } from "./test_context.ts";

Deno.env.set("KV_PATH", ":memory:");

const kvTest = { sanitizeResources: false };
const SESSION_COOKIE = "dmoz_session=abc";
const SAME_ORIGIN = { "sec-fetch-site": "same-origin" };
const CROSS_SITE = { "sec-fetch-site": "cross-site", cookie: SESSION_COOKIE };

function request(
  method: string,
  path: string,
  headers: Record<string, string> = {},
  body?: string,
): Request {
  return new Request(`http://directory.example${path}`, {
    method,
    headers,
    body,
  });
}

async function through(req: Request): Promise<Response> {
  const ctx = {
    ...contextFor(req),
    next: () => Promise.resolve(new Response("reached the route")),
  } as unknown as Context<State>;

  return await (middleware as (ctx: Context<State>) => Promise<Response>)(ctx);
}

const COOKIE_AUTHENTICATED_WRITES = [
  "/admin/api/bulk-delete",
  "/admin/api/bulk-status",
  "/admin/links/new",
  "/admin/categories",
  "/admin/integrity",
  "/dashboard",
  "/profile",
  "/submit",
  "/auth/logout",
  "/auth/login",
  "/auth/register",
  "/auth/oauth/authorize",
  "/api/auth",
];

Deno.test({
  ...kvTest,
  name: "a cross-origin write is refused for every cookie-authenticated route",
  async fn() {
    for (const path of COOKIE_AUTHENTICATED_WRITES) {
      for (const method of ["POST", "PUT", "PATCH", "DELETE"]) {
        const refused = await through(request(method, path, CROSS_SITE));

        assertEquals(refused.status, 403, `${method} ${path}`);
        assertEquals(await refused.text(), "Cross-origin request refused");
      }

      const foreignOrigin = await through(
        request("POST", path, { origin: "https://evil.example" }),
      );
      assertEquals(foreignOrigin.status, 403, path);
    }
  },
});

Deno.test({
  ...kvTest,
  name: "same-origin writes and every read reach the route",
  async fn() {
    for (const path of COOKIE_AUTHENTICATED_WRITES) {
      const sameOrigin = await through(
        request("POST", path, { ...SAME_ORIGIN, cookie: SESSION_COOKIE }),
      );
      assertEquals(await sameOrigin.text(), "reached the route", path);

      const sameHost = await through(
        request("POST", path, { origin: "http://directory.example" }),
      );
      assertEquals(await sameHost.text(), "reached the route", path);
    }

    for (const method of ["GET", "HEAD", "OPTIONS"]) {
      const read = await through(request(method, "/search?q=zig", CROSS_SITE));
      assertEquals(await read.text(), "reached the route", method);
    }
  },
});

Deno.test({
  ...kvTest,
  name:
    "writes that carry no cookie credential keep working from non-browser clients",
  async fn() {
    const bearerWrite = await through(
      request("POST", "/api/v1/links/7/status", {
        authorization: "Bearer a.b.c",
      }),
    );
    assertEquals(await bearerWrite.text(), "reached the route");

    const bearerFromBrowserContext = await through(
      request("POST", "/api/v1/links/7/status", {
        authorization: "bearer a.b.c",
        "sec-fetch-site": "cross-site",
      }),
    );
    assertEquals(await bearerFromBrowserContext.text(), "reached the route");

    for (
      const [path, contentType] of [
        ["/auth/oauth/token", "application/x-www-form-urlencoded"],
        ["/auth/oauth/register", "application/json"],
      ]
    ) {
      const clientCall = await through(
        request("POST", path, { "content-type": contentType }, "{}"),
      );
      assertEquals(await clientCall.text(), "reached the route", path);
    }
  },
});

Deno.test({
  ...kvTest,
  name: "a bearer scheme with no credential does not lift the origin check",
  async fn() {
    const refused = await through(
      request("POST", "/admin/api/bulk-delete", {
        ...CROSS_SITE,
        authorization: "Bearer",
      }),
    );

    assertEquals(refused.status, 403);
  },
});

Deno.test("GET /auth/logout leaves the session alone", async () => {
  const response = await callHandler(
    logout,
    "GET",
    contextFor(request("GET", "/auth/logout")),
  );

  assertEquals(response instanceof Response, false);
});

Deno.test({
  ...kvTest,
  name: "POST /auth/logout clears the cookie and returns home in one request",
  async fn() {
    const signedOut = await callHandler(
      logout,
      "POST",
      contextFor(request("POST", "/auth/logout", SAME_ORIGIN)),
    ) as Response;

    assertEquals(signedOut.status, 303);
    assertEquals(signedOut.headers.get("location"), "/");
    assertEquals(
      signedOut.headers.get("set-cookie")?.includes("Max-Age=0"),
      true,
    );
  },
});

Deno.test({
  ...kvTest,
  name: "/api/auth still refuses text/plain bodies",
  async fn() {
    const registration = JSON.stringify({
      action: "register",
      email: "csrf@example.com",
      username: "csrfuser",
      password: "12345678",
    });

    const textPlain = await callHandler(
      apiAuth,
      "POST",
      contextFor(
        request(
          "POST",
          "/api/auth",
          { "content-type": "text/plain" },
          registration,
        ),
      ),
    ) as Response;
    assertEquals(textPlain.status, 415);
    assertEquals(textPlain.headers.get("set-cookie"), null);

    const registered = await callHandler(
      apiAuth,
      "POST",
      contextFor(
        request(
          "POST",
          "/api/auth",
          { "content-type": "application/json", ...SAME_ORIGIN },
          registration,
        ),
      ),
    ) as Response;
    assertEquals(registered.status, 201);
  },
});
