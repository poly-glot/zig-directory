import { define } from "../../utils.ts";

// /profile is retired in favour of /dashboard?tab=account. Both GET and POST
// 303-redirect; POST callers must re-submit to /dashboard directly.
export const handler = define.handlers({
  GET() {
    return new Response(null, {
      status: 303,
      headers: { Location: "/dashboard?tab=account" },
    });
  },
  POST() {
    return new Response(null, {
      status: 303,
      headers: { Location: "/dashboard?tab=account" },
    });
  },
});
