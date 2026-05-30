import { define } from "../utils.ts";
import { getUserFromRequest } from "../lib/session.ts";

// Resolve the signed-in user once per request and attach to typed state.
// Every downstream handler/page/_layout reads `ctx.state.user` with no cast.
export const handler = define.middleware(async (ctx) => {
  ctx.state.user = await getUserFromRequest(ctx.req);
  return await ctx.next();
});
