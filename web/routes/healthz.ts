import { define } from "../utils.ts";

// Kubernetes liveness/readiness/startup probe target.
//
// The web process is up if this route answers at all. We additionally verify
// the backend is reachable so the pod restarts when dmozdb dies inside the
// same container: a failing liveness probe restarts the pod, and the
// entrypoint relaunches both processes. A bare TCP connect (no binary
// handshake) is enough — if dmozdb crashed, its loopback port stops accepting.
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
