import { define } from "../utils.ts";
import {
  crossOriginRefusal,
  getUserFromRequest,
  isCrossOriginWrite,
} from "../lib/session.ts";

export const handler = define.middleware(async (ctx) => {
  if (isCrossOriginWrite(ctx.req)) return crossOriginRefusal();

  ctx.state.user = await getUserFromRequest(ctx.req);
  return await ctx.next();
});
