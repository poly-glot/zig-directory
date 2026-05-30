/**
 * Stateful binary reader/writer for the dmozdb binary protocol.
 *
 * Replaces all manual DataView + offset tracking with a cursor-based API.
 */

export const encoder = new TextEncoder();
export const decoder = new TextDecoder();

// ── BufferReader ──────────────────────────────────────────────

/** Stateful binary reader that advances a cursor through a buffer. */
export class BufferReader {
  private readonly dv: DataView;
  private pos: number;

  constructor(buf: Uint8Array, offset = 0) {
    this.dv = new DataView(buf.buffer, buf.byteOffset + offset);
    this.pos = 0;
  }

  u8(): number {
    const v = this.dv.getUint8(this.pos);
    this.pos += 1;
    return v;
  }

  u16(): number {
    const v = this.dv.getUint16(this.pos, true);
    this.pos += 2;
    return v;
  }

  u32(): number {
    const v = this.dv.getUint32(this.pos, true);
    this.pos += 4;
    return v;
  }

  u64(): number {
    const v = Number(this.dv.getBigUint64(this.pos, true));
    this.pos += 8;
    return v;
  }

  i64(): number {
    const v = Number(this.dv.getBigInt64(this.pos, true));
    this.pos += 8;
    return v;
  }

  /**
   * Read a Zig `FixedString(N)` — layout is `[N bytes data][u16 len]`.
   * Returns the decoded string of `len` bytes from the data region.
   */
  fixedString(capacity: number): string {
    const start = this.dv.byteOffset + this.pos;
    this.pos += capacity;
    const len = this.u16();
    return decoder.decode(new Uint8Array(this.dv.buffer, start, len));
  }

  /** Read an i64 unix-seconds timestamp and return a Date. */
  timestamp(): Date {
    return new Date(this.i64() * 1000);
  }

  /** Advance the cursor by `n` bytes, returning `this` for chaining. */
  skip(n: number): this {
    this.pos += n;
    return this;
  }

  /** Current cursor position (bytes read so far). */
  get offset(): number {
    return this.pos;
  }
}

// ── BufferWriter ──────────────────────────────────────────────

type Segment =
  | { kind: "u8"; v: number }
  | { kind: "u16"; v: number }
  | { kind: "u32"; v: number }
  | { kind: "u64"; v: number }
  | { kind: "raw"; v: Uint8Array };

/** Chainable binary builder — call methods to append data, then `build()`. */
export class BufferWriter {
  private segments: Segment[] = [];
  private totalSize = 0;

  u8(v: number): this {
    this.segments.push({ kind: "u8", v });
    this.totalSize += 1;
    return this;
  }

  u16(v: number): this {
    this.segments.push({ kind: "u16", v });
    this.totalSize += 2;
    return this;
  }

  u32(v: number): this {
    this.segments.push({ kind: "u32", v });
    this.totalSize += 4;
    return this;
  }

  u64(v: number): this {
    this.segments.push({ kind: "u64", v });
    this.totalSize += 8;
    return this;
  }

  /** Append a u16-length-prefixed UTF-8 string. */
  str(s: string): this {
    const b = encoder.encode(s);
    this.u16(b.length);
    return this.raw(b);
  }

  /** Append raw bytes. */
  raw(b: Uint8Array): this {
    this.segments.push({ kind: "raw", v: b });
    this.totalSize += b.length;
    return this;
  }

  /** Allocate the final buffer and write all segments. */
  build(): Uint8Array {
    const buf = new Uint8Array(this.totalSize);
    const dv = new DataView(buf.buffer);
    let off = 0;
    for (const seg of this.segments) {
      switch (seg.kind) {
        case "u8":
          dv.setUint8(off, seg.v);
          off += 1;
          break;
        case "u16":
          dv.setUint16(off, seg.v, true);
          off += 2;
          break;
        case "u32":
          dv.setUint32(off, seg.v, true);
          off += 4;
          break;
        case "u64":
          dv.setBigUint64(off, BigInt(seg.v), true);
          off += 8;
          break;
        case "raw":
          buf.set(seg.v, off);
          off += seg.v.length;
          break;
      }
    }
    return buf;
  }

  /** Total accumulated size in bytes. */
  get size(): number {
    return this.totalSize;
  }
}
