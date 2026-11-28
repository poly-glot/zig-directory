import { getKv, getUserById, type User } from "./kv-users.ts";

export interface Session {
  userId: string;
  createdAt: string;
  expiresAt: string;
}

const COOKIE_NAME = "dmoz_session";
const SESSION_TTL = 7 * 24 * 60 * 60 * 1000; // 7 days

// ── Cookie helpers ────────────────────────────────────────────

function parseCookies(header: string | null): Record<string, string> {
  if (!header) return {};
  return Object.fromEntries(
    header.split(";").map((c) => {
      const eq = c.indexOf("=");
      return eq === -1
        ? [c.trim(), ""]
        : [c.slice(0, eq).trim(), c.slice(eq + 1).trim()];
    }),
  );
}

function extractSessionId(req: Request): string | null {
  return parseCookies(req.headers.get("cookie"))[COOKIE_NAME] ?? null;
}

// ── Session CRUD ──────────────────────────────────────────────

export async function createSession(
  userId: string,
  req: Request,
): Promise<{ sessionId: string; cookie: string }> {
  const kv = await getKv();
  const sessionId = crypto.randomUUID();
  const now = new Date();
  const session: Session = {
    userId,
    createdAt: now.toISOString(),
    expiresAt: new Date(now.getTime() + SESSION_TTL).toISOString(),
  };
  await kv.set(["sessions", sessionId], session, { expireIn: SESSION_TTL });
  return { sessionId, cookie: makeSessionCookie(sessionId, req) };
}

export async function destroySession(req: Request): Promise<void> {
  const sessionId = extractSessionId(req);
  if (!sessionId) return;
  const kv = await getKv();
  await kv.delete(["sessions", sessionId]);
}

// ── Session lookup ────────────────────────────────────────────

export async function getUserFromRequest(req: Request): Promise<User | null> {
  const sessionId = extractSessionId(req);
  if (!sessionId) return null;

  const kv = await getKv();
  const entry = await kv.get<Session>(["sessions", sessionId]);
  if (!entry.value) return null;

  if (new Date(entry.value.expiresAt) < new Date()) {
    await kv.delete(["sessions", sessionId]);
    return null;
  }

  return getUserById(entry.value.userId);
}

// ── Cookie formatting ─────────────────────────────────────────

function isSecureRequest(req: Request): boolean {
  const forwardedProto = req.headers.get("x-forwarded-proto")?.split(",")[0]
    .trim();
  return new URL(req.url).protocol === "https:" || forwardedProto === "https";
}

function cookieAttributes(req: Request): string {
  const attributes = "Path=/; HttpOnly; SameSite=Lax";
  return isSecureRequest(req) ? `${attributes}; Secure` : attributes;
}

function makeSessionCookie(sessionId: string, req: Request): string {
  const expires = new Date(Date.now() + SESSION_TTL).toUTCString();
  return `${COOKIE_NAME}=${sessionId}; ${
    cookieAttributes(req)
  }; Expires=${expires}`;
}

export function getClearSessionCookie(req: Request): string {
  return `${COOKIE_NAME}=; ${
    cookieAttributes(req)
  }; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Max-Age=0`;
}

export function isSameOriginRequest(req: Request): boolean {
  const fetchSite = req.headers.get("sec-fetch-site");
  if (fetchSite) return fetchSite === "same-origin";

  const origin = req.headers.get("origin");
  if (origin === null) return true;
  return URL.parse(origin)?.host === new URL(req.url).host;
}

const READ_ONLY_METHODS = new Set(["GET", "HEAD", "OPTIONS"]);

export function bearerToken(req: Request): string | null {
  const header = req.headers.get("authorization") ?? "";
  const [scheme, token] = header.split(" ");
  return scheme?.toLowerCase() === "bearer" && token ? token : null;
}

export function isCrossOriginWrite(req: Request): boolean {
  if (READ_ONLY_METHODS.has(req.method)) return false;
  if (bearerToken(req) !== null) return false;

  return !isSameOriginRequest(req);
}

export function crossOriginRefusal(): Response {
  return new Response("Cross-origin request refused", { status: 403 });
}
