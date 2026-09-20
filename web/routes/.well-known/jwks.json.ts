import { define } from "../../utils.ts";

export const handler = define.handlers({
  GET() {
    const raw = Deno.env.get("MCP_JWT_PUBLIC_KEY_JWK");
    if (!raw) return Response.json({ keys: [] });
    return Response.json({ keys: [JSON.parse(raw)] });
  },
});
