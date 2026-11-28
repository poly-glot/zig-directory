import { assertEquals, assertInstanceOf } from "jsr:@std/assert@^1";
import { DmozClient } from "./dmoz-client.ts";
import { loadVisibleLink } from "./link-access.ts";
import { LINK_SIZE, Op } from "./dmoz-protocol.gen.ts";
import type { User, UserRole } from "./kv-users.ts";
import { responseFrame, startFakeBackend } from "./dmoz-fake-backend.ts";
import { userIdToSubmitterId } from "./utils.ts";

const NOT_FOUND = 1;
const STATUS_OFFSET = 496;
const SUBMITTER_OFFSET = 504;
const SUBMITTER = "11111111-1111-4111-8111-111111111111";

function linkRecord(status: number): Uint8Array {
  const record = new Uint8Array(LINK_SIZE);
  const view = new DataView(record.buffer);
  view.setBigUint64(0, 42n, true);
  view.setBigUint64(8, 3n, true);
  view.setUint8(STATUS_OFFSET, status);
  view.setBigUint64(
    SUBMITTER_OFFSET,
    BigInt(userIdToSubmitterId(SUBMITTER)),
    true,
  );
  return record;
}

const STATUS_BYTE = { pending: 0, approved: 1, rejected: 2 } as const;

function viewer(id: string, role: UserRole): User {
  return { id, role } as User;
}

async function visit(
  status: keyof typeof STATUS_BYTE,
  user: User | null,
  rawId = "42",
): Promise<{ outcome: unknown; requested: number }> {
  const backend = startFakeBackend((frame) =>
    frame.op === Op.GetLink
      ? responseFrame(frame.op, linkRecord(STATUS_BYTE[status]))
      : responseFrame(frame.op, new Uint8Array(0), NOT_FOUND)
  );
  const client = new DmozClient("127.0.0.1", backend.port, 2_000);
  try {
    const outcome = await loadVisibleLink(client, rawId, user);
    return { outcome, requested: backend.frames.length };
  } finally {
    client.close();
    await backend.close();
  }
}

Deno.test("an anonymous visitor gets a 404 for a pending or rejected link", async () => {
  for (const status of ["pending", "rejected"] as const) {
    const { outcome } = await visit(status, null);

    assertInstanceOf(outcome, Response);
    assertEquals(outcome.status, 404);
  }
});

Deno.test("an unrelated signed-in user gets a 404 for a pending link", async () => {
  const { outcome } = await visit(
    "pending",
    viewer("22222222-2222-4222-8222-222222222222", "user"),
  );

  assertInstanceOf(outcome, Response);
  assertEquals(outcome.status, 404);
});

Deno.test("the submitter and an admin still see their pending link", async () => {
  for (const user of [viewer(SUBMITTER, "user"), viewer("a", "admin")]) {
    const { outcome } = await visit("pending", user);

    assertEquals(outcome instanceof Response, false);
  }
});

Deno.test("an anonymous visitor still sees an approved link", async () => {
  const { outcome } = await visit("approved", null);

  assertEquals(outcome instanceof Response, false);
});

Deno.test("an id that is not a plain integer is a 404 and never reaches the backend", async () => {
  for (const rawId of ["1.5", "1e3", "0x2a", "abc"]) {
    const { outcome, requested } = await visit("approved", null, rawId);

    assertInstanceOf(outcome, Response);
    assertEquals(outcome.status, 404);
    assertEquals(requested, 0);
  }
});
