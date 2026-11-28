import { assert } from "jsr:@std/assert@^1";
import {
  createSession,
  getClearSessionCookie,
  isSameOriginRequest,
} from "./session.ts";

Deno.env.set("KV_PATH", ":memory:");

const hasSecure = (cookie: string) => /;\s*Secure(;|$)/.test(cookie);

const httpsRequest = new Request("https://directory.example/auth/login");
const proxiedHttpsRequest = new Request("http://web:8000/auth/login", {
  headers: { "x-forwarded-proto": "https" },
});
const localHttpRequest = new Request("http://127.0.0.1:8000/auth/login");

Deno.test({
  name: "session cookies carry Secure on https and behind a TLS proxy",
  sanitizeResources: false,
  async fn() {
    assert(hasSecure((await createSession("u1", httpsRequest)).cookie));
    assert(hasSecure((await createSession("u1", proxiedHttpsRequest)).cookie));
    assert(hasSecure(getClearSessionCookie(httpsRequest)));
    assert(hasSecure(getClearSessionCookie(proxiedHttpsRequest)));
  },
});

Deno.test({
  name: "session cookies stay usable over plain http for local development",
  sanitizeResources: false,
  async fn() {
    assert(!hasSecure((await createSession("u1", localHttpRequest)).cookie));
    assert(!hasSecure(getClearSessionCookie(localHttpRequest)));
  },
});

Deno.test("same-origin checks trust Sec-Fetch-Site, then Origin", () => {
  const post = (headers: Record<string, string>) =>
    new Request("http://directory.example/api/auth", {
      method: "POST",
      headers,
    });

  assert(isSameOriginRequest(post({ "sec-fetch-site": "same-origin" })));
  assert(!isSameOriginRequest(post({ "sec-fetch-site": "same-site" })));
  assert(!isSameOriginRequest(post({ "sec-fetch-site": "cross-site" })));
  assert(isSameOriginRequest(post({ origin: "http://directory.example" })));
  assert(!isSameOriginRequest(post({ origin: "https://evil.example" })));
  assert(!isSameOriginRequest(post({ origin: "null" })));
  assert(isSameOriginRequest(post({})));
});
