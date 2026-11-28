import { assertEquals, assertStringIncludes } from "jsr:@std/assert@^1";
import { getClient, Status, SubStatus } from "../../../../lib/dmoz-client.ts";
import {
  responseFrame,
  startFakeBackend,
} from "../../../../lib/dmoz-fake-backend.ts";
import { handler as searchApi } from "../search.ts";
import { handler as queryApi } from "../links/query.ts";

const SUB_STATUS_OFFSET = 6;

function tooBroadReply(op: number): Uint8Array {
  const reply = responseFrame(op, new Uint8Array(0), Status.Invalid);
  reply[SUB_STATUS_OFFSET] = SubStatus.TooBroad;
  return reply;
}

function get(path: string) {
  const url = new URL(`http://dmoz.test${path}`);
  return { url, req: new Request(url), params: {}, state: {} };
}

Deno.test("the search and facts APIs answer 400 and say how to narrow a too-broad question", async () => {
  const backend = startFakeBackend((frame) => tooBroadReply(frame.op));
  Deno.env.set("DMOZDB_HOST", "127.0.0.1");
  Deno.env.set("DMOZDB_PORT", String(backend.port));

  try {
    for (
      const [route, path] of [
        [searchApi, "/api/v1/search?q=music"],
        [queryApi, "/api/v1/links/query?words=music"],
      ] as const
    ) {
      const response = await (route.GET as (ctx: unknown) => Promise<Response>)(
        get(path),
      );
      const body = await response.json();

      assertEquals(response.status, 400, path);
      assertStringIncludes(body.error, "too broad");
      assertStringIncludes(body.error, "Narrow it");
    }
  } finally {
    getClient().close();
    await backend.close();
  }
});
