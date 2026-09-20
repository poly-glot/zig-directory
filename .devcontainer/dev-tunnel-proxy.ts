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

// The MCP server owns exactly two paths. Everything else is Fresh's — the
// site, the OAuth endpoints under /auth, and the assets its pages reference
// from /routes/... and /@id/..., which an /auth-only rule would strand.
function isMcpPath(pathname: string): boolean {
  return pathname === "/mcp" || pathname.startsWith("/mcp/") ||
    pathname.startsWith("/.well-known/oauth-protected-resource");
}

function stripHeaders(source: Headers, remove: Set<string>): Headers {
  const headers = new Headers(source);
  for (const name of remove) headers.delete(name);
  return headers;
}

function rpcSummary(body: ArrayBuffer | undefined): string {
  if (!body || body.byteLength === 0) return "";
  try {
    const payload = JSON.parse(new TextDecoder().decode(body));
    const messages = Array.isArray(payload) ? payload : [payload];
    return messages
      .map((m) => m?.params?.name ? `${m.method}(${m.params.name})` : m?.method)
      .filter(Boolean)
      .join(",");
  } catch {
    return "";
  }
}

async function handler(req: Request): Promise<Response> {
  const url = new URL(req.url);
  const upstream = isMcpPath(url.pathname) ? MCP : FRESH;
  const target = upstream + url.pathname + url.search;
  const body = req.body ? await req.arrayBuffer() : undefined;

  const stamp = new Date().toISOString().slice(11, 23);
  const who = req.headers.get("authorization") ? "bearer" : "anon";
  const rpc = rpcSummary(body);

  try {
    const upstreamRes = await fetch(target, {
      method: req.method,
      headers: stripHeaders(req.headers, REQUEST_HOP_BY_HOP),
      body,
      redirect: "manual",
    });
    const challenge = upstreamRes.headers.get("www-authenticate");
    console.log(
      `[proxy] ${stamp} ${req.method} ${url.pathname} ${who}` +
        `${rpc ? ` ${rpc}` : ""} -> ${upstreamRes.status}` +
        `${challenge ? ` | WWW-Authenticate: ${challenge}` : ""}`,
    );
    return new Response(upstreamRes.body, {
      status: upstreamRes.status,
      headers: stripHeaders(upstreamRes.headers, RESPONSE_HOP_BY_HOP),
    });
  } catch (err) {
    console.error(
      `[dev-tunnel-proxy] ${req.method} ${url.pathname} -> ${target} failed:`,
      err,
    );
    return new Response("Bad Gateway", { status: 502 });
  }
}

console.log(
  `[dev-tunnel-proxy] :${PORT} -> /mcp and /.well-known/oauth-protected-resource* to ${MCP}; everything else to ${FRESH}`,
);
Deno.serve({ port: PORT, hostname: "0.0.0.0" }, handler);
