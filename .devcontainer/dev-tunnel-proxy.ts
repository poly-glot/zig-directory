const FRESH = "http://127.0.0.1:8000";
const MCP = "http://127.0.0.1:4001";
const PORT = 4000;

const REQUEST_HOP_BY_HOP = new Set([
  "host",
  "connection",
  "content-length",
  "transfer-encoding",
  "keep-alive",
]);
const RESPONSE_HOP_BY_HOP = new Set([
  "connection",
  "content-length",
  "transfer-encoding",
  "keep-alive",
]);

function isFreshPath(pathname: string): boolean {
  return pathname.startsWith("/auth/") ||
    pathname.startsWith("/.well-known/oauth-authorization-server/");
}

function stripHeaders(source: Headers, remove: Set<string>): Headers {
  const headers = new Headers(source);
  for (const name of remove) headers.delete(name);
  return headers;
}

async function handler(req: Request): Promise<Response> {
  const url = new URL(req.url);
  const upstream = isFreshPath(url.pathname) ? FRESH : MCP;
  const target = upstream + url.pathname + url.search;
  const body = req.body ? await req.arrayBuffer() : undefined;

  try {
    const upstreamRes = await fetch(target, {
      method: req.method,
      headers: stripHeaders(req.headers, REQUEST_HOP_BY_HOP),
      body,
      redirect: "manual",
    });
    return new Response(upstreamRes.body, {
      status: upstreamRes.status,
      headers: stripHeaders(upstreamRes.headers, RESPONSE_HOP_BY_HOP),
    });
  } catch (err) {
    console.error(`[dev-tunnel-proxy] ${req.method} ${url.pathname} -> ${target} failed:`, err);
    return new Response("Bad Gateway", { status: 502 });
  }
}

console.log(
  `[dev-tunnel-proxy] :${PORT} -> /auth/*, /.well-known/oauth-authorization-server/* to ${FRESH}; everything else to ${MCP}`,
);
Deno.serve({ port: PORT, hostname: "0.0.0.0" }, handler);
