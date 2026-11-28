import { App } from "fresh";
import { assert, assertEquals, assertFalse } from "jsr:@std/assert@^1";
import type { State } from "../utils.ts";
import {
  contentSecurityPolicy,
  securityHeaders,
  withSecurityHeaders,
} from "./security-headers.ts";

const RENDER_NONCE = Symbol.for("__freshNonce");

function pageWithNonce(nonce: string): Response {
  const response = new Response("<html></html>", {
    headers: { "content-type": "text/html" },
  });
  Object.assign(response, { [RENDER_NONCE]: nonce });
  return response;
}

Deno.test("every response carries HSTS, nosniff, framing and referrer policy", () => {
  const headers = withSecurityHeaders(new Response("ok"), true).headers;

  assertEquals(
    headers.get("strict-transport-security"),
    "max-age=31536000; includeSubDomains",
  );
  assertEquals(headers.get("x-content-type-options"), "nosniff");
  assertEquals(headers.get("x-frame-options"), "DENY");
  assertEquals(
    headers.get("referrer-policy"),
    "strict-origin-when-cross-origin",
  );
});

Deno.test("the policy forbids framing and inline code except Fresh's nonced scripts and styles", () => {
  const policy = contentSecurityPolicy("abc123");

  assert(policy.includes("frame-ancestors 'none'"));
  assert(policy.includes("script-src 'self' 'nonce-abc123'"));
  assert(policy.includes("style-src 'self' 'nonce-abc123'"));
  assert(policy.includes("object-src 'none'"));
  assertFalse(policy.includes("unsafe-inline"));
  assertFalse(policy.includes("unsafe-eval"));
});

Deno.test("the nonce Fresh rendered into the page is the one the policy allows", () => {
  const headers = withSecurityHeaders(pageWithNonce("n0nce"), true).headers;

  assert(headers.get("content-security-policy")?.includes("'nonce-n0nce'"));
});

Deno.test("a page without a nonce gets no inline allowance at all", () => {
  const policy = withSecurityHeaders(new Response("x"), true).headers.get(
    "content-security-policy",
  );

  assert(policy?.includes("script-src 'self';"));
  assert(policy?.includes("style-src 'self';"));
});

Deno.test("an immutable redirect response is rewritten rather than throwing", () => {
  const redirect = Response.redirect("http://dmoz.test/admin", 303);
  const secured = withSecurityHeaders(redirect, true);

  assertEquals(secured.status, 303);
  assertEquals(secured.headers.get("location"), "http://dmoz.test/admin");
  assertEquals(secured.headers.get("x-frame-options"), "DENY");
});

Deno.test("development responses keep the headers but skip the policy", () => {
  const headers = withSecurityHeaders(new Response("ok"), false).headers;

  assertEquals(headers.get("x-content-type-options"), "nosniff");
  assertEquals(headers.get("content-security-policy"), null);
});

Deno.test("a crashing route answers a generic 500 with no stack trace or file path", async () => {
  const app = new App<State>()
    .use(securityHeaders)
    .get("/boom", () => {
      throw new Error("secret detail at /srv/web/lib/secret.ts:9");
    });
  const originalError = console.error;
  console.error = () => {};
  try {
    const response = await app.handler()(new Request("http://dmoz.test/boom"));
    const body = await response.text();

    assertEquals(response.status, 500);
    assertEquals(body, "Internal server error");
    assertFalse(body.includes("secret.ts"));
  } finally {
    console.error = originalError;
  }
});
