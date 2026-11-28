import { page } from "fresh";
import { define } from "../../utils.ts";
import { destroySession, getClearSessionCookie } from "../../lib/session.ts";

export const handler = define.handlers({
  GET(ctx) {
    ctx.state.title = "Sign out";
    return page();
  },

  async POST(ctx) {
    await destroySession(ctx.req);
    return new Response(null, {
      status: 303,
      headers: { Location: "/", "Set-Cookie": getClearSessionCookie(ctx.req) },
    });
  },
});

export default define.page<typeof handler>(function LogoutPage() {
  return (
    <div class="container">
      <h2 class="h2">Sign out</h2>
      <p class="lede mt-16">
        You will need to sign in again to review or submit links.
      </p>
      <form method="POST" class="mt-24">
        <button type="submit" class="btn">Sign out →</button>
      </form>
    </div>
  );
});
