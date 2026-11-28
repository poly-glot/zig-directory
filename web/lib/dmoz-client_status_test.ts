import { assert, assertEquals } from "jsr:@std/assert@^1";
import { DmozClient } from "./dmoz-client.ts";
import {
  type FakeFrame,
  responseFrame,
  startFakeBackend,
} from "./dmoz-fake-backend.ts";

function statusTail(frame: FakeFrame, fixedBytes: number): number[] {
  return [...frame.payload.slice(fixedBytes)];
}

Deno.test("list calls ask for approved links unless the caller opts out with any", async () => {
  const backend = startFakeBackend((frame) => responseFrame(frame.op));
  const client = new DmozClient("127.0.0.1", backend.port);
  const fixedBytes = 8 + 4 + 4;
  try {
    await client.listLinks(5);
    await client.listLinks(5, { status: "any" });
    await client.listLinks(5, { status: "pending" });

    const [defaulted, any, pending] = backend.frames;
    assertEquals(statusTail(defaulted, fixedBytes), [1]);
    assertEquals(statusTail(any, fixedBytes), []);
    assertEquals(statusTail(pending, fixedBytes), [0]);
  } finally {
    client.close();
    await backend.close();
  }
});

Deno.test("every list op defaults to approved and any with a cursor keeps the sentinel", async () => {
  const backend = startFakeBackend((frame) => responseFrame(frame.op));
  const client = new DmozClient("127.0.0.1", backend.port);
  try {
    await client.listAllLinks({ limit: 6 }).catch(() => undefined);
    await client.listMySubmissions(9).catch(() => undefined);
    await client.listSubtreeLinks(4).catch(() => undefined);
    await client.listAllLinks({ status: "any", afterId: 3 }).catch(() =>
      undefined
    );

    const [all, mine, subtree, anyCursor] = backend.frames;
    assertEquals(all.payload.at(-1), 1);
    assertEquals(mine.payload.at(-1), 1);
    assertEquals(subtree.payload.at(-1), 1);
    assertEquals(anyCursor.payload.at(-9), 0xFF);
    assert(anyCursor.payload.length === 4 + 4 + 1 + 8);
  } finally {
    client.close();
    await backend.close();
  }
});
