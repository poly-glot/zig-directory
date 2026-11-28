import {
  assertEquals,
  assertInstanceOf,
  assertRejects,
} from "jsr:@std/assert@^1";
import {
  DmozClient,
  DmozError,
  FILTERED_PAGE_REQUESTS_MAX,
  Status,
} from "./dmoz-client.ts";
import { LINK_SIZE, Op } from "./dmoz-protocol.gen.ts";
import {
  type FakeFrame,
  responseFrame,
  startFakeBackend,
} from "./dmoz-fake-backend.ts";

const SHORT_TIMEOUT_MS = 150;

function pingOnly(frame: FakeFrame): Uint8Array | undefined {
  return frame.op === Op.Ping ? responseFrame(Op.Ping) : undefined;
}

Deno.test("a request timeout resets the connection so the next request is not queued behind a hung one", async () => {
  const backend = startFakeBackend((frame) =>
    frame.connection === 1 ? undefined : pingOnly(frame)
  );
  const client = new DmozClient("127.0.0.1", backend.port, SHORT_TIMEOUT_MS);
  try {
    await assertRejects(() => client.ping(), Error, "timed out");

    await client.ping();
    assertEquals(backend.connectionCount(), 2);
  } finally {
    client.close();
    await backend.close();
  }
});

Deno.test("an oversized frame fails only its own request and leaves the shared connection alone", async () => {
  const backend = startFakeBackend((frame) => {
    if (frame.op !== Op.Ping) return undefined;
    return responseFrame(Op.Ping);
  });
  const client = new DmozClient("127.0.0.1", backend.port, 2_000);
  try {
    await client.ping();
    const before = backend.frames.length;

    const error = await assertRejects(() => client.search("a".repeat(70_000)));
    assertInstanceOf(error, DmozError);
    assertEquals(error.status, Status.Invalid);

    await client.ping();
    assertEquals(backend.connectionCount(), 1);
    assertEquals(backend.frames.length, before + 1);
  } finally {
    client.close();
    await backend.close();
  }
});

interface FakeResponse {
  status: number;
  subStatus: number;
  count: number;
  payload: Uint8Array;
}

// The server reads a bounded number of rows per filtered page, so the rows it
// has to give sit behind pages that come back empty with a cursor. This fake
// answers `emptyPages` such pages, cursor 1, 2, 3 ..., then one link with no
// further page, and records the cursor each request carried.
function fakeServer(emptyPages: number) {
  const cursors: number[] = [];
  const request = (_op: number, payload: Uint8Array): Promise<FakeResponse> => {
    // list_all_links: [u32 offset][u32 limit], then [u8 status][u64 after_id].
    const view = new DataView(payload.buffer, payload.byteOffset);
    const afterId = payload.length === 17
      ? Number(view.getBigUint64(9, true))
      : 0;
    cursors.push(afterId);
    const reply = new Uint8Array(LINK_SIZE + 8);
    const replyView = new DataView(reply.buffer);
    if (afterId < emptyPages) {
      replyView.setBigUint64(0, BigInt(afterId + 1), true);
      return Promise.resolve({
        status: 0,
        subStatus: 0,
        count: 0,
        payload: reply.subarray(0, 8),
      });
    }
    replyView.setBigUint64(0, 92_002n, true);
    return Promise.resolve({
      status: 0,
      subStatus: 0,
      count: 1,
      payload: reply,
    });
  };
  return { cursors, request };
}

function clientWith(server: ReturnType<typeof fakeServer>): DmozClient {
  const client = new DmozClient("127.0.0.1", 1);
  Object.assign(client, { request: server.request });
  return client;
}

Deno.test("a filtered link list follows empty pages to the first row", async () => {
  const server = fakeServer(3);
  const page = await clientWith(server).listAllLinks({ status: "pending" });

  assertEquals(page.links.map((link) => link.id), [92_002]);
  assertEquals(page.nextAfterId, 0);
  assertEquals(server.cursors, [0, 1, 2, 3]);
});

Deno.test("a filtered link list stops following at the request bound and keeps the cursor", async () => {
  const server = fakeServer(FILTERED_PAGE_REQUESTS_MAX + 10);
  const page = await clientWith(server).listAllLinks({ status: "pending" });

  assertEquals(page.links, []);
  assertEquals(page.nextAfterId, FILTERED_PAGE_REQUESTS_MAX);
  assertEquals(server.cursors.length, FILTERED_PAGE_REQUESTS_MAX);
});
