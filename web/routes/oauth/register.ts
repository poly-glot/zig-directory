import { define } from "../../utils.ts";
import { registerClient, validateRedirectUris } from "../../lib/oauth.ts";
import { oauthError } from "./_lib/errors.ts";

export const handler = define.handlers({
  async POST(ctx) {
    let body: Record<string, unknown>;
    try {
      body = await ctx.req.json();
    } catch {
      return oauthError("invalid_client_metadata", "Invalid JSON body");
    }

    const authMethod = body.token_endpoint_auth_method;
    if (authMethod !== undefined && authMethod !== "none") {
      return oauthError(
        "invalid_client_metadata",
        "Only public clients (token_endpoint_auth_method=none) are supported",
      );
    }

    const redirectUris = validateRedirectUris(body.redirect_uris);
    if (!redirectUris) {
      return oauthError(
        "invalid_redirect_uri",
        "redirect_uris must be a non-empty array of https:// or loopback URLs",
      );
    }

    const clientName = typeof body.client_name === "string"
      ? body.client_name
      : "MCP client";

    const client = await registerClient(redirectUris, clientName);
    return Response.json({
      client_id: client.clientId,
      client_id_issued_at: Math.floor(
        new Date(client.createdAt).getTime() / 1000,
      ),
      client_name: client.clientName,
      redirect_uris: client.redirectUris,
      token_endpoint_auth_method: "none",
      grant_types: ["authorization_code", "refresh_token"],
      response_types: ["code"],
    }, { status: 201 });
  },
});
