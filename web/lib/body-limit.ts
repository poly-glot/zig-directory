import { define } from "../utils.ts";

export const REQUEST_BODY_MAX_BYTES = 64 * 1024;

function tooLarge(): Response {
  return new Response("Request body too large", {
    status: 413,
    headers: { "content-type": "text/plain" },
  });
}

function declaredLength(request: Request): number | undefined {
  const raw = request.headers.get("content-length");
  return raw !== null && /^\d+$/.test(raw) ? Number(raw) : undefined;
}

async function readWithin(
  body: ReadableStream<Uint8Array>,
  maxBytes: number,
): Promise<Uint8Array<ArrayBuffer> | undefined> {
  const chunks: Uint8Array[] = [];
  let received = 0;
  const reader = body.getReader();

  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;

    received += value.length;
    if (received > maxBytes) {
      await reader.cancel();
      return undefined;
    }
    chunks.push(value);
  }

  const bytes = new Uint8Array(new ArrayBuffer(received));
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.length;
  }
  return bytes;
}

export async function boundBody(
  request: Request,
  maxBytes: number,
): Promise<Request | Response> {
  const declared = declaredLength(request);
  if (declared !== undefined && declared > maxBytes) return tooLarge();
  if (declared !== undefined || request.body === null) return request;

  const bytes = await readWithin(request.body, maxBytes);
  if (bytes === undefined) return tooLarge();

  return new Request(request.url, {
    method: request.method,
    headers: request.headers,
    body: bytes,
  });
}

export const bodyLimit = define.middleware(async (ctx) => {
  const bounded = await boundBody(ctx.req, REQUEST_BODY_MAX_BYTES);
  if (bounded instanceof Response) return bounded;

  ctx.req = bounded;
  return ctx.next();
});
