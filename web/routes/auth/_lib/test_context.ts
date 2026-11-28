import type { Context } from "fresh";
import type { User } from "../../../lib/kv-users.ts";
import type { State } from "../../../utils.ts";

export function contextFor(
  req: Request,
  user: User | null = null,
  remoteAddress = "203.0.113.7",
): Context<State> {
  return {
    req,
    url: new URL(req.url),
    state: { user },
    params: {},
    info: {
      remoteAddr: { transport: "tcp", hostname: remoteAddress, port: 50000 },
    },
  } as unknown as Context<State>;
}

type HandlersByMethod = Record<string, (ctx: Context<State>) => unknown>;

export async function callHandler(
  handler: unknown,
  method: string,
  ctx: Context<State>,
): Promise<unknown> {
  return await (handler as HandlersByMethod)[method](ctx);
}
