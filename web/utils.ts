import { createDefine } from "fresh";
import type { User } from "./lib/kv-users.ts";

// Shape of `ctx.state` shared across middleware, _layout, and routes.
// Populated by routes/_middleware.ts on every request.
export interface State {
  user: User | null;
  /** Page title set by each route; the brand suffix and a site-wide default
   * are applied in routes/_app.tsx. Unset → site default. */
  title?: string;
  /** Meta description set by each route; unset → site default. */
  description?: string;
}

export const define = createDefine<State>();
