export interface FakeFrame {
  op: number;
  payload: Uint8Array;
  connection: number;
}

export interface FakeBackend {
  port: number;
  frames: FakeFrame[];
  connectionCount(): number;
  close(): Promise<void>;
}

const REQUEST_HEADER_BYTES = 8;
const RESPONSE_HEADER_BYTES = 10;

export function responseFrame(
  op: number,
  payload: Uint8Array = new Uint8Array(0),
  status = 0,
): Uint8Array {
  const frame = new Uint8Array(RESPONSE_HEADER_BYTES + payload.length);
  const view = new DataView(frame.buffer);
  view.setUint32(0, frame.length, true);
  view.setUint8(4, op);
  view.setUint8(5, status);
  frame.set(payload, RESPONSE_HEADER_BYTES);
  return frame;
}

function takeFrames(
  pending: Uint8Array,
  connection: number,
): { frames: FakeFrame[]; rest: Uint8Array } {
  const frames: FakeFrame[] = [];
  let rest = pending;
  while (rest.length >= REQUEST_HEADER_BYTES) {
    const length = new DataView(rest.buffer, rest.byteOffset).getUint32(
      0,
      true,
    );
    if (rest.length < length) break;
    frames.push({
      op: rest[4],
      payload: rest.slice(REQUEST_HEADER_BYTES, length),
      connection,
    });
    rest = rest.slice(length);
  }
  return { frames, rest };
}

function closeQuietly(conn: Deno.Conn): void {
  try {
    conn.close();
  } catch {
    return;
  }
}

async function serveConnection(
  conn: Deno.Conn,
  connection: number,
  frames: FakeFrame[],
  respond: (frame: FakeFrame) => Uint8Array | undefined,
): Promise<void> {
  const chunk = new Uint8Array(65536);
  let pending: Uint8Array = new Uint8Array(0);
  try {
    for (;;) {
      const n = await conn.read(chunk);
      if (n === null) return closeQuietly(conn);

      const joined = new Uint8Array(pending.length + n);
      joined.set(pending);
      joined.set(chunk.subarray(0, n), pending.length);

      const taken = takeFrames(joined, connection);
      pending = taken.rest;
      for (const frame of taken.frames) {
        frames.push(frame);
        const reply = respond(frame);
        if (reply) await conn.write(reply);
      }
    }
  } catch {
    closeQuietly(conn);
    return;
  }
}

export function startFakeBackend(
  respond: (frame: FakeFrame) => Uint8Array | undefined,
): FakeBackend {
  const listener = Deno.listen({ hostname: "127.0.0.1", port: 0 });
  const frames: FakeFrame[] = [];
  const conns: Deno.Conn[] = [];
  const serving: Promise<void>[] = [];

  const accepting = (async () => {
    try {
      for await (const conn of listener) {
        conns.push(conn);
        serving.push(serveConnection(conn, conns.length, frames, respond));
      }
    } catch {
      return;
    }
  })();

  return {
    port: (listener.addr as Deno.NetAddr).port,
    frames,
    connectionCount: () => conns.length,
    async close() {
      listener.close();
      for (const conn of conns) closeQuietly(conn);
      await accepting;
      await Promise.all(serving);
    },
  };
}
