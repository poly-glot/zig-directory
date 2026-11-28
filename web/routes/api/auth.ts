import { define } from "../../utils.ts";
import {
  authenticateUser,
  createUser,
  updateUser,
  type User,
} from "../../lib/kv-users.ts";
import {
  createSession,
  destroySession,
  getClearSessionCookie,
} from "../../lib/session.ts";
import {
  clientAddress,
  consumeAttempt,
  refundAttempt,
} from "../../lib/rate-limit.ts";

const sanitize = ({ passwordHash: _, ...user }: User) => user;

const json = (data: unknown, status: number, headers?: HeadersInit) =>
  Response.json(data, { status, headers });

const isJsonRequest = (req: Request) =>
  req.headers.get("content-type")?.split(";")[0].trim().toLowerCase() ===
    "application/json";

export const handler = define.handlers({
  async POST(ctx) {
    if (!isJsonRequest(ctx.req)) {
      return json({ error: "Content-Type must be application/json" }, 415);
    }

    let body: Record<string, string>;
    try {
      body = await ctx.req.json();
    } catch (e) {
      console.error("Failed to parse auth request body:", e);
      return json({ error: "Invalid request body" }, 400);
    }

    const address = clientAddress(ctx.req, ctx.info);
    switch (body.action) {
      case "login": {
        const { email, password } = body;
        if (!email || !password) {
          return json({ error: "Email and password are required" }, 400);
        }
        if (!(await consumeAttempt("login", address))) {
          return json({ error: "Too many sign-in attempts" }, 429);
        }
        const user = await authenticateUser(email, password);
        if (!user) return json({ error: "Invalid email or password" }, 401);
        await refundAttempt("login", address);
        const { cookie } = await createSession(user.id, ctx.req);
        return json({ user: sanitize(user) }, 200, { "Set-Cookie": cookie });
      }

      case "register": {
        const { email, username, password, displayName } = body;
        if (!email || !username || !password) {
          return json(
            { error: "Email, username, and password are required" },
            400,
          );
        }
        if (password.length < 8) {
          return json({ error: "Password must be at least 8 characters" }, 400);
        }
        if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
          return json({ error: "Invalid email format" }, 400);
        }
        if (!(await consumeAttempt("register", address))) {
          return json({ error: "Too many accounts created" }, 429);
        }
        try {
          const user = await createUser(email, username, password);
          if (displayName) {
            await updateUser(user.id, { displayName });
            user.displayName = displayName;
          }
          const { cookie } = await createSession(user.id, ctx.req);
          return json({ user: sanitize(user) }, 201, { "Set-Cookie": cookie });
        } catch (err) {
          return json({ error: (err as Error).message }, 409);
        }
      }

      case "logout": {
        await destroySession(ctx.req);
        return json({ ok: true }, 200, {
          "Set-Cookie": getClearSessionCookie(ctx.req),
        });
      }

      default:
        return json({ error: "Unknown action" }, 400);
    }
  },
});
