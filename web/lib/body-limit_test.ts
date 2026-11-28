import { App } from "fresh";
import { assertEquals, assertInstanceOf } from "jsr:@std/assert@^1";
import { bodyLimit, boundBody, REQUEST_BODY_MAX_BYTES } from "./body-limit.ts";
import type { State } from "../utils.ts";

const CAP = 16;

function chunked(
  sizes: number[],
): { stream: ReadableStream<Uint8Array>; pulled: () => number } {
  let pulled = 0;
  const stream = new ReadableStream<Uint8Array>({
    pull(controller) {
      if (pulled === sizes.length) return controller.close();
      controller.enqueue(new Uint8Array(sizes[pulled++]).fill(97));
    },
  });
  return { stream, pulled: () => pulled };
}

function post(body: BodyInit, headers: HeadersInit = {}): Request {
  return new Request("http://dmoz.test/submit", {
    method: "POST",
    headers,
    body,
    duplex: "half",
  } as RequestInit);
}

Deno.test("a declared Content-Length over the cap is refused before the body is read", async () => {
  const request = post("x".repeat(CAP + 1));
  assertEquals(request.headers.get("content-length"), null);

  const declared = new Request(request, {
    headers: { "content-length": String(CAP + 1) },
  });
  const outcome = await boundBody(declared, CAP);
  assertInstanceOf(outcome, Response);
  assertEquals(outcome.status, 413);
});

Deno.test("a chunked body with no length is counted and refused once it passes the cap", async () => {
  const { stream, pulled } = chunked([10, 10, 10, 10, 10]);
  const outcome = await boundBody(post(stream), CAP);

  assertInstanceOf(outcome, Response);
  assertEquals(outcome.status, 413);
  assertEquals(pulled() < 5, true);
});

Deno.test("a chunked body within the cap is passed on intact", async () => {
  const { stream } = chunked([5, 5, 5]);
  const outcome = await boundBody(post(stream), CAP);

  assertInstanceOf(outcome, Request);
  assertEquals(await outcome.text(), "a".repeat(15));
});

Deno.test("a small declared body and a bodyless GET pass untouched", async () => {
  const small = post("hello", { "content-length": "5" });
  assertEquals(await boundBody(small, CAP), small);

  const get = new Request("http://dmoz.test/");
  assertEquals(await boundBody(get, CAP), get);
});

Deno.test("the root middleware answers 413 and never reaches the route", async () => {
  let reached = false;
  const app = new App<State>()
    .use(bodyLimit)
    .post("/submit", () => {
      reached = true;
      return new Response("ok");
    });

  const tooBig = new Uint8Array(REQUEST_BODY_MAX_BYTES + 1);
  const response = await app.handler()(post(tooBig));

  assertEquals(response.status, 413);
  assertEquals(reached, false);
  await response.body?.cancel();
});

Deno.test("the root middleware lets a body at the cap reach the route", async () => {
  const app = new App<State>()
    .use(bodyLimit)
    .post(
      "/submit",
      async (ctx) => new Response(String((await ctx.req.text()).length)),
    );

  const atCap = new Uint8Array(REQUEST_BODY_MAX_BYTES).fill(97);
  const response = await app.handler()(post(atCap));

  assertEquals(await response.text(), String(REQUEST_BODY_MAX_BYTES));
});
