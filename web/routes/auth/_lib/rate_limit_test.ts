import { assertEquals } from "jsr:@std/assert@^1";
import { createUser } from "../../../lib/kv-users.ts";
import { RATE_LIMITS } from "../../../lib/rate-limit.ts";
import { handler as apiAuth } from "../../api/auth.ts";
import { handler as token } from "../oauth/token.ts";
import { handler as clientRegistration } from "../oauth/register.ts";
import { callHandler, contextFor } from "./test_context.ts";

Deno.env.set("KV_PATH", ":memory:");

const kvTest = { sanitizeResources: false };

function loginRequest(password: string): Request {
  return new Request("http://directory.example/api/auth", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      action: "login",
      email: "limited@example.com",
      password,
    }),
  });
}

async function statusOf(
  handler: unknown,
  request: () => Request,
  address: string,
): Promise<number> {
  const response = await callHandler(
    handler,
    "POST",
    contextFor(request(), null, address),
  ) as Response;
  await response.body?.cancel();
  return response.status;
}

Deno.test({
  ...kvTest,
  name: "failed sign-ins are limited per address; successful ones are not",
  async fn() {
    await createUser("limited@example.com", "limited", "right-password");
    const { attemptsMax } = RATE_LIMITS.login;

    for (let attempt = 0; attempt < attemptsMax + 2; attempt++) {
      assertEquals(
        await statusOf(apiAuth, () => loginRequest("right-password"), "a1"),
        200,
      );
    }

    for (let attempt = 0; attempt < attemptsMax; attempt++) {
      assertEquals(
        await statusOf(apiAuth, () => loginRequest("wrong-password"), "a2"),
        401,
      );
    }
    assertEquals(
      await statusOf(apiAuth, () => loginRequest("right-password"), "a2"),
      429,
    );
  },
});

Deno.test({
  ...kvTest,
  name: "the token endpoint answers 429 past its limit",
  async fn() {
    const tokenRequest = () =>
      new Request("http://directory.example/auth/oauth/token", {
        method: "POST",
        body: new URLSearchParams({ grant_type: "x", client_id: "unknown" }),
      });
    const { attemptsMax } = RATE_LIMITS.token;

    for (let attempt = 0; attempt < attemptsMax; attempt++) {
      assertEquals(await statusOf(token, tokenRequest, "t1"), 400);
    }
    assertEquals(await statusOf(token, tokenRequest, "t1"), 429);
  },
});

Deno.test({
  ...kvTest,
  name: "dynamic client registration answers 429 past its limit",
  async fn() {
    const registrationRequest = () =>
      new Request("http://directory.example/auth/oauth/register", {
        method: "POST",
        body: JSON.stringify({ redirect_uris: ["https://c.example/cb"] }),
      });
    const { attemptsMax } = RATE_LIMITS.clientRegistration;

    for (let attempt = 0; attempt < attemptsMax; attempt++) {
      assertEquals(
        await statusOf(clientRegistration, registrationRequest, "r1"),
        201,
      );
    }
    assertEquals(
      await statusOf(clientRegistration, registrationRequest, "r1"),
      429,
    );
  },
});
