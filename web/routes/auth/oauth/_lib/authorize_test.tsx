import { assert, assertEquals, assertMatch } from "jsr:@std/assert@^1";
import type { ComponentProps } from "preact";
import { renderToString } from "npm:preact-render-to-string@^6.6.3";
import type { User } from "../../../../lib/kv-users.ts";
import {
  consumeAuthorizationCode,
  registerClient,
} from "../../../../lib/oauth.ts";
import { RATE_LIMITS } from "../../../../lib/rate-limit.ts";
import AuthorizePage, { handler } from "../authorize.tsx";
import { callHandler, contextFor } from "../../_lib/test_context.ts";

Deno.env.set("KV_PATH", ":memory:");
Deno.env.set("MCP_RESOURCE_URL", "https://directory.example/mcp");

const kvTest = { sanitizeResources: false };

function authorizeRequest(clientId: string, query: string): Request {
  return new Request(
    `http://directory.example/auth/oauth/authorize?client_id=${clientId}` +
      `&redirect_uri=https://evil.example/landing&${query}`,
  );
}

Deno.test({
  ...kvTest,
  name: "authorize never redirects to a client's URI before sign-in",
  async fn() {
    const client = await registerClient(
      ["https://evil.example/landing"],
      "Anyone",
    );
    const badRequests = [
      "response_type=x",
      "response_type=code&code_challenge_method=plain",
      "response_type=code&code_challenge_method=S256&code_challenge=c" +
      "&resource=https://elsewhere.example/mcp",
    ];

    for (const query of badRequests) {
      const response = await callHandler(
        handler,
        "GET",
        contextFor(authorizeRequest(client.clientId, query)),
      ) as Response;
      assertEquals(response.status, 400, query);
      assertEquals(response.headers.get("location"), null, query);
    }
  },
});

const signedInAdmin: User = {
  id: "admin-1",
  email: "admin@directory.example",
  username: "admin",
  passwordHash: "",
  role: "admin",
  displayName: "Admin",
  bio: "",
  avatarUrl: "",
  createdAt: "",
  updatedAt: "",
};

type ConsentProps = ComponentProps<typeof AuthorizePage>;

const validAuthorizeQuery = "response_type=code&code_challenge_method=S256" +
  "&code_challenge=c&resource=https://directory.example/mcp";

Deno.test({
  ...kvTest,
  name: "the consent screen names the host the grant is sent to",
  async fn() {
    const client = await registerClient(
      ["https://evil.example/landing"],
      "Claude",
    );
    const consent = await callHandler(
      handler,
      "GET",
      contextFor(
        authorizeRequest(client.clientId, validAuthorizeQuery),
        signedInAdmin,
      ),
    ) as { data: ConsentProps["data"] };
    const html = renderToString(
      <AuthorizePage
        {...({ data: consent.data } as ConsentProps)}
      />,
    );

    assertMatch(html, /<p class="lede[^"]*"><strong>evil\.example<\/strong>/);
    assert(!html.includes("<strong>Claude</strong>"));
  },
});

Deno.test({
  ...kvTest,
  name: "an approved grant carries only the allow-listed scope",
  async fn() {
    const client = await registerClient(["https://client.example/cb"], "C");
    const approval = new Request(
      "http://directory.example/auth/oauth/authorize",
      {
        method: "POST",
        body: new URLSearchParams({
          client_id: client.clientId,
          redirect_uri: "https://client.example/cb",
          code_challenge: "c",
          resource: "https://directory.example/mcp",
          scope: "mcp admin everything",
          action: "allow",
        }),
      },
    );

    const response = await callHandler(
      handler,
      "POST",
      contextFor(approval, signedInAdmin),
    ) as Response;
    const code = new URL(response.headers.get("location")!).searchParams.get(
      "code",
    );
    assert(code);

    const record = await consumeAuthorizationCode(code);
    assertEquals(record?.scope, "mcp");
  },
});

Deno.test({
  ...kvTest,
  name: "authorize limits client lookups per address before sign-in",
  async fn() {
    const lookup = () =>
      contextFor(
        authorizeRequest("unregistered-client", ""),
        null,
        "198.51.100.9",
      );
    const statusOf = async (method: string) => {
      const response = await callHandler(handler, method, lookup()) as Response;
      await response.body?.cancel();
      return response.status;
    };

    for (
      let attempt = 0;
      attempt < RATE_LIMITS.authorize.attemptsMax;
      attempt++
    ) {
      assertEquals(await statusOf("GET"), 400);
    }
    assertEquals(await statusOf("GET"), 429);
  },
});
