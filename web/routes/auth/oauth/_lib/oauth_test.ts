import { assert, assertEquals, assertNotEquals } from "jsr:@std/assert@^1";
import { exportJWK, exportPKCS8, generateKeyPair } from "jose";
import {
  consumeAuthorizationCode,
  createAuthorizationCode,
  issueRefreshToken,
  redeemRefreshToken,
  redirectUriMatches,
  registerClient,
  signAccessToken,
  validateRedirectUris,
  verifyBearerToken,
  verifyPkce,
} from "../../../../lib/oauth.ts";
import { isCimdClientId, resolveCimdClient } from "../../../../lib/cimd.ts";

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

Deno.test(
  "verifyBearerToken accepts a validly signed token and rejects tampering",
  async () => {
    const { privateKey, publicKey } = await generateKeyPair("RS256", {
      modulusLength: 2048,
      extractable: true,
    });
    const publicJwk = await exportJWK(publicKey);
    publicJwk.alg = "RS256";

    Deno.env.set("OAUTH_ISSUER_URL", "https://issuer.example.com");
    Deno.env.set("MCP_RESOURCE_URL", "https://resource.example.com/mcp");
    Deno.env.set(
      "MCP_JWT_PRIVATE_KEY_PEM",
      (await exportPKCS8(privateKey)).trim().replaceAll("\n", "\\n"),
    );
    Deno.env.set("MCP_JWT_PUBLIC_KEY_JWK", JSON.stringify(publicJwk));

    const { accessToken } = await signAccessToken({
      userId: "user-1",
      role: "admin",
      clientId: "client-1",
      resource: "https://resource.example.com/mcp",
      scope: "mcp",
    });

    assertEquals(await verifyBearerToken(accessToken), {
      userId: "user-1",
      role: "admin",
    });
    assertEquals(
      await verifyBearerToken(accessToken.slice(0, -2) + "xx"),
      null,
    );
    assertEquals(await verifyBearerToken("not-a-jwt"), null);

    const wrongAudience = await signAccessToken({
      userId: "user-1",
      role: "admin",
      clientId: "client-1",
      resource: "https://someone-elses-resource.example.com/mcp",
      scope: "mcp",
    });
    assertEquals(await verifyBearerToken(wrongAudience.accessToken), null);
  },
);

Deno.test("redirect matching is exact for plain patterns", () => {
  assert(redirectUriMatches(
    "https://claude.ai/api/mcp/auth_callback",
    "https://claude.ai/api/mcp/auth_callback",
  ));
  assert(
    !redirectUriMatches(
      "https://evil.com/cb",
      "https://claude.ai/api/mcp/auth_callback",
    ),
  );
});

Deno.test("loopback patterns accept any port (RFC 8252 §7.3)", () => {
  assert(
    redirectUriMatches("http://127.0.0.1:53121/cb", "http://127.0.0.1/cb"),
  );
  assert(
    redirectUriMatches("http://localhost:9999/cb", "http://localhost:*/cb"),
  );
  assert(
    !redirectUriMatches("http://example.com:9999/cb", "http://example.com/cb"),
  );
});

Deno.test("redirect matching rejects userinfo and dot-segment bypasses", () => {
  assert(
    !redirectUriMatches(
      "http://localhost@evil.com/cb",
      "http://localhost:*/cb",
    ),
  );
  assert(
    !redirectUriMatches(
      "https://claude.ai/api/../../steal",
      "https://claude.ai/api/*",
    ),
  );
});

Deno.test("wildcard host patterns only match subdomains", () => {
  assert(
    redirectUriMatches(
      "https://app.example.com/cb",
      "https://*.example.com/cb",
    ),
  );
  assert(
    !redirectUriMatches(
      "https://evil-example.com/cb",
      "https://*.example.com/cb",
    ),
  );
});

Deno.test("CIMD client ids must be https URLs", () => {
  assert(isCimdClientId("https://claude.ai/.well-known/oauth-client"));
  assert(!isCimdClientId("6fdc54d5-d1e4-4259-a836-c391342b76e2"));
  assert(!isCimdClientId("http://insecure.example.com/client"));
});

Deno.test("CIMD rejects non-https, root-path and private-host documents", async () => {
  assertEquals(await resolveCimdClient("http://example.com/client"), null);
  assertEquals(await resolveCimdClient("https://example.com/"), null);
  assertEquals(await resolveCimdClient("https://localhost/client"), null);
  assertEquals(await resolveCimdClient("https://127.0.0.1/client"), null);
});
