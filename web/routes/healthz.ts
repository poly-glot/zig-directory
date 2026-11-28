import { define } from "../utils.ts";

const HOST = Deno.env.get("DMOZDB_HOST") ?? "localhost";
const PORT = Number(Deno.env.get("DMOZDB_PORT") ?? "8080");

async function backendReachable(): Promise<boolean> {
  let conn: Deno.TcpConn | undefined;
  try {
    conn = await Deno.connect({ hostname: HOST, port: PORT });
    return true;
  } catch {
    return false;
  } finally {
    conn?.close();
  }
}

export const handler = define.handlers({
  async GET() {
    const ok = await backendReachable();
    return new Response(ok ? "ok" : "backend unreachable", {
      status: ok ? 200 : 503,
      headers: { "content-type": "text/plain" },
    });
  },
});
