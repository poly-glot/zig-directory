import { define } from "../utils.ts";

const RENDER_NONCE = Symbol.for("__freshNonce");
const ENFORCE_CSP = import.meta.env?.PROD === true;

const STATIC_HEADERS: Readonly<Record<string, string>> = {
  "referrer-policy": "strict-origin-when-cross-origin",
  "strict-transport-security": "max-age=31536000; includeSubDomains",
  "x-content-type-options": "nosniff",
  "x-frame-options": "DENY",
};

type NoncedResponse = Record<symbol, string | undefined>;

export function contentSecurityPolicy(nonce: string | undefined): string {
  const inline = nonce ? ` 'nonce-${nonce}'` : "";
  return [
    "default-src 'self'",
    `script-src 'self'${inline}`,
    `style-src 'self'${inline}`,
    "img-src 'self' data:",
    "font-src 'self'",
    "connect-src 'self'",
    "object-src 'none'",
    "base-uri 'self'",
    "frame-ancestors 'none'",
  ].join("; ");
}

export function withSecurityHeaders(
  response: Response,
  enforceCsp: boolean = ENFORCE_CSP,
): Response {
  const nonce = (response as unknown as NoncedResponse)[RENDER_NONCE];
  const headers = new Headers(response.headers);
  for (const [name, value] of Object.entries(STATIC_HEADERS)) {
    headers.set(name, value);
  }
  if (enforceCsp) {
    headers.set("content-security-policy", contentSecurityPolicy(nonce));
  }

  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

export const securityHeaders = define.middleware(async (ctx) => {
  return withSecurityHeaders(await ctx.next());
});
