import { define } from "../../utils.ts";
import { destroySession, getClearSessionCookie } from "../../lib/session.ts";

export const handler = define.handlers({
  async GET(ctx) {
    await destroySession(ctx.req);
    return new Response(null, {
      status: 303,
      headers: { Location: "/", "Set-Cookie": getClearSessionCookie() },
    });
  },
});
