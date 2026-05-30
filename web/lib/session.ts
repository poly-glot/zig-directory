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
  return { sessionId, cookie: makeSessionCookie(sessionId) };
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

function makeSessionCookie(sessionId: string): string {
  const expires = new Date(Date.now() + SESSION_TTL).toUTCString();
  return `${COOKIE_NAME}=${sessionId}; Path=/; HttpOnly; SameSite=Lax; Expires=${expires}`;
}

export function getClearSessionCookie(): string {
  return `${COOKIE_NAME}=; Path=/; HttpOnly; SameSite=Lax; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Max-Age=0`;
}
