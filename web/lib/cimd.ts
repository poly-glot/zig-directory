export interface CimdClient {
  clientId: string;
  redirectUris: string[];
  clientName: string;
}

interface CacheEntry {
  client: CimdClient;
  expiresAt: number;
}

const CACHE_TTL = 10 * 60 * 1000;
const FETCH_TIMEOUT = 5000;
const MAX_DOCUMENT_BYTES = 64 * 1024;
const PUBLIC_AUTH_METHODS = new Set(["none"]);

const cache = new Map<string, CacheEntry>();

function ipv4IsPrivate(address: string): boolean {
  const octets = address.split(".").map(Number);
  if (
    octets.length !== 4 ||
    octets.some((o) => !Number.isInteger(o) || o < 0 || o > 255)
  ) {
    return true;
  }
  const [a, b] = octets;
  if (a === 0 || a === 10 || a === 127) return true;
  if (a === 169 && b === 254) return true;
  if (a === 172 && b >= 16 && b <= 31) return true;
  if (a === 192 && b === 168) return true;
  if (a === 100 && b >= 64 && b <= 127) return true;
  return a >= 224;
}

function ipv6IsPrivate(address: string): boolean {
  const value = address.toLowerCase();
  if (value === "::1" || value === "::") return true;
  const mapped = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/.exec(value);
  if (mapped) return ipv4IsPrivate(mapped[1]);
  const head = parseInt(value.split(":")[0] || "0", 16);
  if ((head & 0xfe00) === 0xfc00) return true;
  if ((head & 0xffc0) === 0xfe80) return true;
  return (head & 0xff00) === 0xff00;
}

async function resolvesToPublicAddress(hostname: string): Promise<boolean> {
  if (/^\d+\.\d+\.\d+\.\d+$/.test(hostname) || hostname.includes(":")) {
    return false;
  }

  const lookups = await Promise.allSettled([
    Deno.resolveDns(hostname, "A"),
    Deno.resolveDns(hostname, "AAAA"),
  ]);
  const addresses = lookups.flatMap((r) =>
    r.status === "fulfilled" ? r.value : []
  );
  if (addresses.length === 0) return false;

  return addresses.every((address) =>
    address.includes(":") ? !ipv6IsPrivate(address) : !ipv4IsPrivate(address)
  );
}

async function validateDocumentUrl(clientId: string): Promise<URL | null> {
  let url: URL;
  try {
    url = new URL(clientId);
  } catch {
    return null;
  }
  if (url.protocol !== "https:") return null;
  if (!url.hostname) return null;
  if (url.pathname === "" || url.pathname === "/") return null;
  if (url.username || url.password) return null;
  if (url.hash) return null;
  if (!(await resolvesToPublicAddress(url.hostname))) return null;
  return url;
}

function validateRedirectUris(raw: unknown): string[] | null {
  if (!Array.isArray(raw) || raw.length === 0) return null;
  const uris: string[] = [];
  for (const entry of raw) {
    if (typeof entry !== "string" || !entry.trim()) return null;
    const scheme = /^([a-zA-Z][a-zA-Z0-9+.-]*):/.exec(entry);
    if (!scheme) return null;
    if (!entry.startsWith("urn:") && !entry.includes("//")) return null;
    uris.push(entry);
  }
  return uris;
}

function toClient(
  clientId: string,
  document: Record<string, unknown>,
): CimdClient | null {
  if (document.client_id !== clientId) return null;

  const authMethod = document.token_endpoint_auth_method ?? "none";
  if (typeof authMethod !== "string" || !PUBLIC_AUTH_METHODS.has(authMethod)) {
    return null;
  }

  const redirectUris = validateRedirectUris(document.redirect_uris);
  if (!redirectUris) return null;

  return {
    clientId,
    redirectUris,
    clientName: typeof document.client_name === "string"
      ? document.client_name
      : "MCP client",
  };
}

export function isCimdClientId(clientId: string): boolean {
  return clientId.startsWith("https://");
}

export async function resolveCimdClient(
  clientId: string,
): Promise<CimdClient | null> {
  const cached = cache.get(clientId);
  if (cached && cached.expiresAt > Date.now()) return cached.client;

  const url = await validateDocumentUrl(clientId);
  if (!url) return null;

  let response: Response;
  try {
    response = await fetch(url, {
      headers: { accept: "application/json" },
      redirect: "error",
      signal: AbortSignal.timeout(FETCH_TIMEOUT),
    });
  } catch {
    return null;
  }
  if (!response.ok) {
    await response.body?.cancel();
    return null;
  }

  const body = await response.text();
  if (body.length > MAX_DOCUMENT_BYTES) return null;

  let document: unknown;
  try {
    document = JSON.parse(body);
  } catch {
    return null;
  }
  if (typeof document !== "object" || document === null) return null;

  const client = toClient(clientId, document as Record<string, unknown>);
  if (client) {
    cache.set(clientId, { client, expiresAt: Date.now() + CACHE_TTL });
  }
  return client;
}
