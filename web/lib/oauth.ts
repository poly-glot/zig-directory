import { encodeBase64Url } from "jsr:@std/encoding@^1/base64url";
import { importJWK, importPKCS8, jwtVerify, SignJWT } from "jose";
import { isCimdClientId, resolveCimdClient } from "./cimd.ts";
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

export async function resolveClient(
  clientId: string,
): Promise<OAuthClient | null> {
  if (!isCimdClientId(clientId)) return getClient(clientId);

  const client = await resolveCimdClient(clientId);
  if (!client) return null;
  return { ...client, createdAt: new Date(0).toISOString() };
}

function hostMatches(host: string, pattern: string): boolean {
  if (pattern === "*") return true;
  if (pattern.startsWith("*.")) return host.endsWith(pattern.slice(1));
  return host === pattern;
}

function pathMatches(path: string, pattern: string): boolean {
  if (!pattern.includes("*")) return path === pattern;
  const expression = pattern
    .split("*")
    .map((part) => part.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"))
    .join(".*");
  return new RegExp(`^${expression}$`).test(path);
}

export function redirectUriMatches(uri: string, pattern: string): boolean {
  const parts = /^([a-zA-Z][a-zA-Z0-9+.-]*):\/\/([^/?#]*)([^?#]*)$/.exec(
    pattern,
  );
  if (!parts) return uri === pattern;

  let target: URL;
  try {
    target = new URL(uri);
  } catch {
    return false;
  }
  if (target.username || target.password) return false;
  if (target.pathname.split("/").some((s) => s === "." || s === "..")) {
    return false;
  }

  const [, scheme, authority, path] = parts;
  if (target.protocol !== `${scheme.toLowerCase()}:`) return false;

  const portAt = authority.lastIndexOf(":");
  const patternHost = portAt === -1 ? authority : authority.slice(0, portAt);
  const patternPort = portAt === -1 ? null : authority.slice(portAt + 1);
  if (!hostMatches(target.hostname, patternHost.toLowerCase())) return false;

  const loopback = ["127.0.0.1", "localhost", "[::1]", "::1"].includes(
    patternHost.toLowerCase(),
  );
  if (patternPort !== null && patternPort !== "*") {
    if (target.port !== patternPort) return false;
  } else if (patternPort === null && !loopback) {
    if (target.port !== "") return false;
  }

  return pathMatches(target.pathname, path || "/");
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

export async function verifyPkce(
  codeVerifier: string,
  codeChallenge: string,
): Promise<boolean> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(codeVerifier),
  );
  return encodeBase64Url(digest) === codeChallenge;
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
  const issuer = Deno.env.get("OAUTH_ISSUER_URL") ??
    "http://127.0.0.1:8000/auth";
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

let verificationKey: Awaited<ReturnType<typeof importJWK>> | null = null;

async function getVerificationKey(): Promise<
  Awaited<ReturnType<typeof importJWK>>
> {
  if (!verificationKey) {
    const jwk = JSON.parse(Deno.env.get("MCP_JWT_PUBLIC_KEY_JWK") ?? "{}");
    verificationKey = await importJWK(jwk, "RS256");
  }
  return verificationKey;
}

// The scope the MCP resource advertises in scopes_supported and demands in its
// WWW-Authenticate challenge. Verified here too: a token that never carried it
// must not be spendable on a write just because its audience and role match.
const MCP_SCOPE = "mcp";

function grantsScope(claim: unknown, required: string): boolean {
  return typeof claim === "string" && claim.split(" ").includes(required);
}

export async function verifyBearerToken(
  token: string,
): Promise<{ userId: string; role: string } | null> {
  const issuer = Deno.env.get("OAUTH_ISSUER_URL") ??
    "http://127.0.0.1:8000/auth";
  const audience = Deno.env.get("MCP_RESOURCE_URL") ??
    "http://127.0.0.1:8765/mcp";
  try {
    const key = await getVerificationKey();
    const { payload } = await jwtVerify(token, key, { issuer, audience });
    if (typeof payload.sub !== "string" || typeof payload.role !== "string") {
      return null;
    }
    if (!grantsScope(payload.scope, MCP_SCOPE)) {
      return null;
    }
    return { userId: payload.sub, role: payload.role };
  } catch {
    return null;
  }
}
