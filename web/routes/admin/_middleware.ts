import { define } from "../../utils.ts";

// Gate the entire /admin/* tree on `state.user.role === "admin"`.
// Anonymous or non-admin users get redirected to login.
export const handler = define.middleware((ctx) => {
  const user = ctx.state.user;
  if (!user || user.role !== "admin") {
    return new Response(null, {
      status: 303,
      headers: { Location: "/auth/login?redirect=/admin" },
    });
  }
  return ctx.next();
});
