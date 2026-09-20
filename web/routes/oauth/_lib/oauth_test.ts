import { assert, assertEquals, assertNotEquals } from "jsr:@std/assert@^1";
import {
  consumeAuthorizationCode,
  createAuthorizationCode,
  issueRefreshToken,
  redeemRefreshToken,
  registerClient,
  validateRedirectUris,
  verifyPkce,
} from "../../../lib/oauth.ts";

Deno.env.set("KV_PATH", ":memory:");

Deno.test("redirect_uris must be non-empty https or loopback URLs", () => {
  assertEquals(validateRedirectUris([]), null);
  assertEquals(validateRedirectUris(["ftp://example.com/cb"]), null);
  assertEquals(validateRedirectUris("https://example.com/cb"), null);
  assertEquals(
    validateRedirectUris(["https://example.com/cb"]),
    ["https://example.com/cb"],
  );
  assertEquals(
    validateRedirectUris(["http://127.0.0.1:9000/cb"]),
    ["http://127.0.0.1:9000/cb"],
  );
});

Deno.test("PKCE: matching verifier passes, mismatched verifier fails", async () => {
  const verifier = "a".repeat(64);
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(verifier),
  );
  const challenge = btoa(String.fromCharCode(...new Uint8Array(digest)))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

  assert(await verifyPkce(verifier, challenge));
  assert(!(await verifyPkce("b".repeat(64), challenge)));
});

// getKv() opens one process-wide Deno.Kv handle the first time any test
// below touches it; Deno's resource sanitizer blames whichever test
// happened to trigger that open for a "leak" it never owned, so these
// KV-backed tests share `sanitizeResources: false`.

Deno.test({
  name: "an authorization code can be redeemed exactly once",
  sanitizeResources: false,
  async fn() {
    const client = await registerClient(["https://example.com/cb"], "Test");
    const code = await createAuthorizationCode({
      userId: "user-1",
      clientId: client.clientId,
      redirectUri: "https://example.com/cb",
      codeChallenge: "challenge",
      resource: "https://mcp.example.com/mcp",
      scope: "mcp",
    });

    const first = await consumeAuthorizationCode(code);
    assert(first);
    assertEquals(first.userId, "user-1");

    const second = await consumeAuthorizationCode(code);
    assertEquals(second, null);
  },
});

Deno.test({
  name: "an unknown authorization code is rejected",
  sanitizeResources: false,
  async fn() {
    const result = await consumeAuthorizationCode(crypto.randomUUID());
    assertEquals(result, null);
  },
});

Deno.test({
  name: "refresh token rotation invalidates the old token",
  sanitizeResources: false,
  async fn() {
    const client = await registerClient(["https://example.com/cb"], "Test");
    const token = await issueRefreshToken({
      userId: "user-1",
      clientId: client.clientId,
      scope: "mcp",
      resource: "https://mcp.example.com/mcp",
    });

    const redeemed = await redeemRefreshToken(token);
    assert(redeemed);
    assertNotEquals(redeemed.nextToken, token);

    const reuseOldToken = await redeemRefreshToken(token);
    assertEquals(reuseOldToken, null);
  },
});
