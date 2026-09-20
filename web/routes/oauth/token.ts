import { define } from "../../utils.ts";
import { getUserById } from "../../lib/kv-users.ts";
import {
  consumeAuthorizationCode,
  getClient,
  issueRefreshToken,
  redeemRefreshToken,
  signAccessToken,
  verifyPkce,
} from "../../lib/oauth.ts";
import { oauthError } from "./_lib/errors.ts";

async function authorizationCodeGrant(form: FormData): Promise<Response> {
  const code = form.get("code")?.toString() ?? "";
  const clientId = form.get("client_id")?.toString() ?? "";
  const redirectUri = form.get("redirect_uri")?.toString() ?? "";
  const codeVerifier = form.get("code_verifier")?.toString() ?? "";

  const record = await consumeAuthorizationCode(code);
  if (!record) return oauthError("invalid_grant", "Unknown or expired code");

  if (record.clientId !== clientId || record.redirectUri !== redirectUri) {
    return oauthError("invalid_grant", "client_id or redirect_uri mismatch");
  }
  if (
    !codeVerifier || !(await verifyPkce(codeVerifier, record.codeChallenge))
  ) {
    return oauthError("invalid_grant", "PKCE verification failed");
  }

  const user = await getUserById(record.userId);
  if (!user) return oauthError("invalid_grant", "Account no longer exists");

  const { accessToken, expiresIn } = await signAccessToken({
    userId: user.id,
    role: user.role,
    clientId: record.clientId,
    resource: record.resource,
    scope: record.scope,
  });
  const refreshToken = await issueRefreshToken({
    userId: user.id,
    clientId: record.clientId,
    scope: record.scope,
    resource: record.resource,
  });

  return Response.json({
    access_token: accessToken,
    token_type: "Bearer",
    expires_in: expiresIn,
    refresh_token: refreshToken,
    scope: record.scope,
  });
}

async function refreshTokenGrant(form: FormData): Promise<Response> {
  const clientId = form.get("client_id")?.toString() ?? "";
  const refreshToken = form.get("refresh_token")?.toString() ?? "";

  const redeemed = await redeemRefreshToken(refreshToken);
  if (!redeemed) {
    return oauthError("invalid_grant", "Unknown or expired refresh token");
  }
  if (redeemed.record.clientId !== clientId) {
    return oauthError("invalid_grant", "client_id mismatch");
  }

  const user = await getUserById(redeemed.record.userId);
  if (!user) return oauthError("invalid_grant", "Account no longer exists");

  const { accessToken, expiresIn } = await signAccessToken({
    userId: user.id,
    role: user.role,
    clientId: redeemed.record.clientId,
    resource: redeemed.record.resource,
    scope: redeemed.record.scope,
  });

  return Response.json({
    access_token: accessToken,
    token_type: "Bearer",
    expires_in: expiresIn,
    refresh_token: redeemed.nextToken,
    scope: redeemed.record.scope,
  });
}

export const handler = define.handlers({
  async POST(ctx) {
    const form = await ctx.req.formData();
    const grantType = form.get("grant_type")?.toString();
    const clientId = form.get("client_id")?.toString() ?? "";

    if (!(await getClient(clientId))) {
      return oauthError("invalid_client", "Unknown client_id");
    }

    if (grantType === "authorization_code") {
      return await authorizationCodeGrant(form);
    }
    if (grantType === "refresh_token") {
      return await refreshTokenGrant(form);
    }
    return oauthError("unsupported_grant_type", "Unknown grant_type");
  },
});
