import { assert, assertEquals } from "jsr:@std/assert@^1";
import {
  clientAddress,
  consumeAttempt,
  RATE_LIMITS,
  refundAttempt,
} from "./rate-limit.ts";

Deno.env.set("KV_PATH", ":memory:");

const kvTest = { sanitizeResources: false };

Deno.test({
  ...kvTest,
  name: "a client gets its window's attempts and no more",
  async fn() {
    const { attemptsMax } = RATE_LIMITS.register;
    for (let attempt = 0; attempt < attemptsMax; attempt++) {
      assert(await consumeAttempt("register", "198.51.100.1"));
    }

    assertEquals(await consumeAttempt("register", "198.51.100.1"), false);
    assert(await consumeAttempt("register", "198.51.100.2"));
  },
});

Deno.test({
  ...kvTest,
  name: "a refunded attempt can be used again",
  async fn() {
    const { attemptsMax } = RATE_LIMITS.login;
    for (let attempt = 0; attempt < attemptsMax; attempt++) {
      assert(await consumeAttempt("login", "198.51.100.3"));
    }

    await refundAttempt("login", "198.51.100.3");
    assert(await consumeAttempt("login", "198.51.100.3"));
    assertEquals(await consumeAttempt("login", "198.51.100.3"), false);
  },
});

Deno.test("the client address is the one the nearest proxy saw", () => {
  const info = {
    remoteAddr: { transport: "tcp", hostname: "10.0.0.5", port: 1 },
  } as Deno.ServeHandlerInfo;
  const request = (headers: Record<string, string>) =>
    new Request("http://directory.example/", { headers });

  assertEquals(clientAddress(request({}), info), "10.0.0.5");
  assertEquals(
    clientAddress(
      request({ "x-forwarded-for": "1.2.3.4, 203.0.113.9" }),
      info,
    ),
    "203.0.113.9",
  );
});
