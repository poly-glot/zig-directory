import { assertEquals } from "jsr:@std/assert@^1";
import { DmozClient } from "./dmoz-client.ts";
import { LINK_SIZE, Op } from "./dmoz-protocol.gen.ts";
import { responseFrame, startFakeBackend } from "./dmoz-fake-backend.ts";

const LINK_ID_OFFSET = 0;
const LINK_STATUS_OFFSET = 496;
const STATUS_BY_ID: Record<number, number> = { 1: 0, 2: 1, 3: 2 };

function searchPayload(): Uint8Array {
  const ids = Object.keys(STATUS_BY_ID).map(Number);
  const payload = new Uint8Array(2 + 2 + ids.length * (LINK_SIZE + 1));
  const view = new DataView(payload.buffer);
  view.setUint16(2, ids.length, true);

  ids.forEach((id, index) => {
    const base = 4 + index * (LINK_SIZE + 1);
    view.setBigUint64(base + LINK_ID_OFFSET, BigInt(id), true);
    view.setUint8(base + LINK_STATUS_OFFSET, STATUS_BY_ID[id]);
  });
  return payload;
}

Deno.test("search returns only approved links unless the caller asks for any", async () => {
  const backend = startFakeBackend(() =>
    responseFrame(Op.Search, searchPayload())
  );
  const client = new DmozClient("127.0.0.1", backend.port);
  try {
    const defaulted = await client.search("zorblax");
    const any = await client.search("zorblax", { status: "any" });
    const rejected = await client.search("zorblax", { status: "rejected" });

    assertEquals(defaulted.links.map((link) => link.id), [2]);
    assertEquals(any.links.map((link) => link.id), [1, 2, 3]);
    assertEquals(rejected.links.map((link) => link.id), [3]);
  } finally {
    client.close();
    await backend.close();
  }
});
