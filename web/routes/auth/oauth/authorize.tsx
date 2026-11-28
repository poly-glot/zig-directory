import { page } from "fresh";
import { define } from "../../../utils.ts";
import {
  createAuthorizationCode,
  MCP_SCOPE,
  type OAuthClient,
  redirectUriMatches,
  resolveClient,
} from "../../../lib/oauth.ts";
import { clientAddress, consumeAttempt } from "../../../lib/rate-limit.ts";
import { oauthError } from "./_lib/errors.ts";

interface Data {
  clientName: string;
  clientId: string;
  redirectUri: string;
  redirectHost: string;
  codeChallenge: string;
  resource: string;
  state: string;
}

function expectedResource(): string {
  return Deno.env.get("MCP_RESOURCE_URL") ?? "http://127.0.0.1:8765/mcp";
}

function redirectWithError(
  redirectUri: string,
  state: string,
  error: string,
): Response {
  const target = new URL(redirectUri);
  target.searchParams.set("error", error);
  if (state) target.searchParams.set("state", state);
  return new Response(null, {
    status: 303,
    headers: { Location: target.toString() },
  });
}

async function resolveClientAndRedirect(
  clientId: string,
  redirectUri: string,
  address: string,
): Promise<
  { ok: true; client: OAuthClient } | { ok: false; response: Response }
> {
  if (!(await consumeAttempt("authorize", address))) {
    return {
      ok: false,
      response: oauthError("temporarily_unavailable", "Too many requests", 429),
    };
  }

  const client = clientId ? await resolveClient(clientId) : null;
  if (!client) {
    return {
      ok: false,
      response: oauthError("invalid_client", "Unknown client_id"),
    };
  }
  if (!client.redirectUris.some((p) => redirectUriMatches(redirectUri, p))) {
    return {
      ok: false,
      response: oauthError(
        "invalid_request",
        "redirect_uri does not match a registered URI",
      ),
    };
  }
  return { ok: true, client };
}

export const handler = define.handlers<Data>({
  async GET(ctx) {
    const params = ctx.url.searchParams;
    const clientId = params.get("client_id") ?? "";
    const redirectUri = params.get("redirect_uri") ?? "";

    const resolved = await resolveClientAndRedirect(
      clientId,
      redirectUri,
      clientAddress(ctx.req, ctx.info),
    );
    if (!resolved.ok) return resolved.response;
    const { client } = resolved;

    const state = params.get("state") ?? "";
    const responseType = params.get("response_type");
    const codeChallenge = params.get("code_challenge") ?? "";
    const codeChallengeMethod = params.get("code_challenge_method");
    const resource = params.get("resource") ?? "";

    if (responseType !== "code") {
      return oauthError(
        "unsupported_response_type",
        "response_type must be code",
      );
    }
    if (codeChallengeMethod !== "S256" || !codeChallenge) {
      return oauthError("invalid_request", "PKCE with S256 is required");
    }
    if (resource !== expectedResource()) {
      return oauthError("invalid_target", "Unknown resource");
    }

    if (!ctx.state.user) {
      const target = ctx.url.pathname + ctx.url.search;
      return new Response(null, {
        status: 303,
        headers: {
          Location: `/auth/login?redirect=${encodeURIComponent(target)}`,
        },
      });
    }

    ctx.state.title = "Authorize access";
    return page({
      clientName: client.clientName,
      clientId,
      redirectUri,
      redirectHost: new URL(redirectUri).host || redirectUri,
      codeChallenge,
      resource,
      state,
    });
  },

  async POST(ctx) {
    const form = await ctx.req.formData();
    const clientId = form.get("client_id")?.toString() ?? "";
    const redirectUri = form.get("redirect_uri")?.toString() ?? "";
    const codeChallenge = form.get("code_challenge")?.toString() ?? "";
    const resource = form.get("resource")?.toString() ?? "";
    const state = form.get("state")?.toString() ?? "";
    const action = form.get("action")?.toString();

    const resolved = await resolveClientAndRedirect(
      clientId,
      redirectUri,
      clientAddress(ctx.req, ctx.info),
    );
    if (!resolved.ok) return resolved.response;

    if (!ctx.state.user) {
      return oauthError("access_denied", "Not authenticated", 401);
    }

    if (action !== "allow") {
      return redirectWithError(redirectUri, state, "access_denied");
    }
    if (!codeChallenge || resource !== expectedResource()) {
      return redirectWithError(redirectUri, state, "invalid_request");
    }

    const code = await createAuthorizationCode({
      userId: ctx.state.user.id,
      clientId,
      redirectUri,
      codeChallenge,
      resource,
      scope: MCP_SCOPE,
    });

    const target = new URL(redirectUri);
    target.searchParams.set("code", code);
    if (state) target.searchParams.set("state", state);
    return new Response(null, {
      status: 303,
      headers: { Location: target.toString() },
    });
  },
});

export default define.page<typeof handler>(function AuthorizePage(props) {
  const {
    clientName,
    clientId,
    redirectUri,
    redirectHost,
    codeChallenge,
    resource,
    state,
  } = props.data;
  return (
    <div class="container">
      <h2 class="h2">Authorize access</h2>
      <p class="lede mt-16">
        <strong>{redirectHost}</strong>{" "}
        wants to access your dmozdb account to call its MCP tools on your
        behalf.
      </p>
      <p class="mt-16">
        It calls itself “{clientName}”. Allowing sends your access to{" "}
        <strong>{redirectHost}</strong>, so only allow it if you trust that
        site.
      </p>
      <form method="POST" class="row between mt-24">
        <input type="hidden" name="client_id" value={clientId} />
        <input type="hidden" name="redirect_uri" value={redirectUri} />
        <input type="hidden" name="code_challenge" value={codeChallenge} />
        <input type="hidden" name="resource" value={resource} />
        <input type="hidden" name="state" value={state} />
        <button type="submit" name="action" value="deny" class="btn link">
          Deny
        </button>
        <button type="submit" name="action" value="allow" class="btn">
          Allow →
        </button>
      </form>
    </div>
  );
});
