import { importPKCS8, SignJWT } from "jose";
import { getKv } from "./kv-users.ts";

export interface OAuthClient {
  clientId: string;
  redirectUris: string[];
  clientName: string;
  createdAt: string;
}

export interface AuthorizationCodeRecord {
  userId: string;
  clientId: string;
  redirectUri: string;
  codeChallenge: string;
  resource: string;
  scope: string;
  expiresAt: string;
}

export interface RefreshTokenRecord {
  userId: string;
  clientId: string;
  scope: string;
  resource: string;
  expiresAt: string;
}

const AUTH_CODE_TTL = 60 * 1000;
const REFRESH_TOKEN_TTL = 30 * 24 * 60 * 60 * 1000;
const ACCESS_TOKEN_TTL_SECONDS = 60 * 60;

function isLoopbackOrHttps(raw: string): boolean {
  try {
    const url = new URL(raw);
    if (url.protocol === "https:") return true;
    return url.protocol === "http:" &&
      (url.hostname === "127.0.0.1" || url.hostname === "localhost");
  } catch {
    return false;
  }
}

export function validateRedirectUris(raw: unknown): string[] | null {
  if (!Array.isArray(raw) || raw.length === 0) return null;
  if (!raw.every((uri) => typeof uri === "string" && isLoopbackOrHttps(uri))) {
    return null;
  }
  return raw;
}

export async function registerClient(
  redirectUris: string[],
  clientName: string,
): Promise<OAuthClient> {
  const kv = await getKv();
  const client: OAuthClient = {
    clientId: crypto.randomUUID(),
    redirectUris,
    clientName,
    createdAt: new Date().toISOString(),
  };
  await kv.set(["oauth_clients", client.clientId], client);
  return client;
}

export async function getClient(clientId: string): Promise<OAuthClient | null> {
  const kv = await getKv();
  const entry = await kv.get<OAuthClient>(["oauth_clients", clientId]);
  return entry.value ?? null;
}

export async function createAuthorizationCode(
  record: Omit<AuthorizationCodeRecord, "expiresAt">,
): Promise<string> {
  const kv = await getKv();
  const code = crypto.randomUUID();
  const full: AuthorizationCodeRecord = {
    ...record,
    expiresAt: new Date(Date.now() + AUTH_CODE_TTL).toISOString(),
  };
  await kv.set(["oauth_codes", code], full, { expireIn: AUTH_CODE_TTL });
  return code;
}

export async function consumeAuthorizationCode(
  code: string,
): Promise<AuthorizationCodeRecord | null> {
  const kv = await getKv();
  const entry = await kv.get<AuthorizationCodeRecord>(["oauth_codes", code]);
  if (!entry.value) return null;

  const result = await kv.atomic().check(entry).delete(["oauth_codes", code])
    .commit();
  if (!result.ok) return null;

  if (new Date(entry.value.expiresAt) < new Date()) return null;
  return entry.value;
}

export async function issueRefreshToken(
  record: Omit<RefreshTokenRecord, "expiresAt">,
): Promise<string> {
  const kv = await getKv();
  const token = crypto.randomUUID();
  const full: RefreshTokenRecord = {
    ...record,
    expiresAt: new Date(Date.now() + REFRESH_TOKEN_TTL).toISOString(),
  };
  await kv.set(["oauth_refresh_tokens", token], full, {
    expireIn: REFRESH_TOKEN_TTL,
  });
  return token;
}

export async function redeemRefreshToken(
  token: string,
): Promise<{ record: RefreshTokenRecord; nextToken: string } | null> {
  const kv = await getKv();
  const entry = await kv.get<RefreshTokenRecord>([
    "oauth_refresh_tokens",
    token,
  ]);
  if (!entry.value) return null;

  if (new Date(entry.value.expiresAt) < new Date()) {
    await kv.delete(["oauth_refresh_tokens", token]);
    return null;
  }

  const result = await kv.atomic().check(entry)
    .delete(["oauth_refresh_tokens", token]).commit();
  if (!result.ok) return null;

  const nextToken = await issueRefreshToken({
    userId: entry.value.userId,
    clientId: entry.value.clientId,
    scope: entry.value.scope,
    resource: entry.value.resource,
  });
  return { record: entry.value, nextToken };
}

function base64UrlEncode(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(
    /=+$/,
    "",
  );
}

export async function verifyPkce(
  codeVerifier: string,
  codeChallenge: string,
): Promise<boolean> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(codeVerifier),
  );
  return base64UrlEncode(new Uint8Array(digest)) === codeChallenge;
}

let signingKey: Awaited<ReturnType<typeof importPKCS8>> | null = null;

async function getSigningKey(): Promise<
  Awaited<ReturnType<typeof importPKCS8>>
> {
  if (!signingKey) {
    const pem = (Deno.env.get("MCP_JWT_PRIVATE_KEY_PEM") ?? "").replaceAll(
      "\\n",
      "\n",
    );
    signingKey = await importPKCS8(pem, "RS256");
  }
  return signingKey;
}

export async function signAccessToken(
  { userId, role, clientId, resource, scope }: {
    userId: string;
    role: string;
    clientId: string;
    resource: string;
    scope: string;
  },
): Promise<{ accessToken: string; expiresIn: number }> {
  const issuer = Deno.env.get("OAUTH_ISSUER_URL") ?? "http://127.0.0.1:8000";
  const publicKeyJwk = JSON.parse(
    Deno.env.get("MCP_JWT_PUBLIC_KEY_JWK") ?? "{}",
  );
  const privateKey = await getSigningKey();
  const accessToken = await new SignJWT({ role, client_id: clientId, scope })
    .setProtectedHeader({ alg: "RS256", kid: publicKeyJwk.kid })
    .setSubject(userId)
    .setIssuer(issuer)
    .setAudience(resource)
    .setIssuedAt()
    .setExpirationTime(`${ACCESS_TOKEN_TTL_SECONDS}s`)
    .sign(privateKey);
  return { accessToken, expiresIn: ACCESS_TOKEN_TTL_SECONDS };
}
