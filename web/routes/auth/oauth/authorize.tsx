import { page } from "fresh";
import { define } from "../../../utils.ts";
import {
  createAuthorizationCode,
  type OAuthClient,
  redirectUriMatches,
  resolveClient,
} from "../../../lib/oauth.ts";
import { oauthError } from "./_lib/errors.ts";

interface Data {
  clientName: string;
  clientId: string;
  redirectUri: string;
  codeChallenge: string;
  resource: string;
  scope: string;
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
): Promise<
  { ok: true; client: OAuthClient } | { ok: false; response: Response }
> {
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

    const resolved = await resolveClientAndRedirect(clientId, redirectUri);
    if (!resolved.ok) return resolved.response;
    const { client } = resolved;

    const state = params.get("state") ?? "";
    const responseType = params.get("response_type");
    const codeChallenge = params.get("code_challenge") ?? "";
    const codeChallengeMethod = params.get("code_challenge_method");
    const resource = params.get("resource") ?? "";
    const scope = params.get("scope") ?? "mcp";

    if (responseType !== "code") {
      return redirectWithError(redirectUri, state, "unsupported_response_type");
    }
    if (codeChallengeMethod !== "S256" || !codeChallenge) {
      return redirectWithError(redirectUri, state, "invalid_request");
    }
    if (resource !== expectedResource()) {
      return redirectWithError(redirectUri, state, "invalid_target");
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
      codeChallenge,
      resource,
      scope,
      state,
    });
  },

  async POST(ctx) {
    const form = await ctx.req.formData();
    const clientId = form.get("client_id")?.toString() ?? "";
    const redirectUri = form.get("redirect_uri")?.toString() ?? "";
    const codeChallenge = form.get("code_challenge")?.toString() ?? "";
    const resource = form.get("resource")?.toString() ?? "";
    const scope = form.get("scope")?.toString() ?? "mcp";
    const state = form.get("state")?.toString() ?? "";
    const action = form.get("action")?.toString();

    const resolved = await resolveClientAndRedirect(clientId, redirectUri);
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
      scope,
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
    codeChallenge,
    resource,
    scope,
    state,
  } = props.data;
  return (
    <div class="container">
      <h2 class="h2">Authorize access</h2>
      <p class="lede mt-16">
        <strong>{clientName}</strong>{" "}
        wants to access your dmozdb account to call its MCP tools on your
        behalf.
      </p>
      <form method="POST" class="row between mt-24">
        <input type="hidden" name="client_id" value={clientId} />
        <input type="hidden" name="redirect_uri" value={redirectUri} />
        <input type="hidden" name="code_challenge" value={codeChallenge} />
        <input type="hidden" name="resource" value={resource} />
        <input type="hidden" name="scope" value={scope} />
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
