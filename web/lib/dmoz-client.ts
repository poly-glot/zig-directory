/**
 * Binary protocol TCP client for the dmozdb Zig backend.
 *
 * Protocol frame format:
 *   Request:  [4B total_len LE][1B op][1B flags][2B count LE][payload...]   (8-byte header)
 *   Response: [4B total_len LE][1B op][1B status][1B sub_status][1B reserved][2B count LE][payload...]   (10-byte header)
 *
 * `total_len` INCLUDES the header. Request and response use different
 * header widths: request stays 8 bytes; response grew to 10 bytes when
 * `sub_status` (offset 6) and `reserved` (offset 7) were appended in the
 * operations-surface uplift slice.
 */

import { BufferReader, BufferWriter, decoder, encoder } from "./buffer.ts";
import {
  type Category,
  CATEGORY_SIZE,
  type Link,
  LINK_SIZE,
  type LinkStatus,
  Op,
  readCategory,
  readLink,
  type Religion,
  RELIGIONS,
  Status,
  STATUS_MSG,
  statusToCode,
  SUB_STATUS_MSG,
  SubStatus,
} from "./dmoz-protocol.gen.ts";

export { type Category, type Link, type LinkStatus, Op, Status, SubStatus };

export type LinkStatusFilter = LinkStatus | "any";
export { linkStatusFromByte } from "./dmoz-protocol.gen.ts";

const REQUEST_HEADER_SIZE = 8;
const RESPONSE_HEADER_SIZE = 10;
const REQUEST_TIMEOUT_MS = 10_000;
const REQUEST_FRAME_MAX_BYTES = 65_535;

/**
 * A filtered list page reads a bounded number of index rows on the server
 * (50,000 for ops 13/16/27, 10,000 for op 17), so a rare status such as the
 * moderation queue's pending links can come back empty with a cursor. The
 * client follows that cursor, up to this many requests, so a caller sees an
 * empty page only at the end or after 3.2M rows; past the bound the page
 * keeps its cursor and the caller's "next" carries on from there.
 */
export const FILTERED_PAGE_REQUESTS_MAX = 64;

/** Server cap on a single get_categories_by_ids request. */
export const GET_CATEGORIES_BY_IDS_MAX = 200;

/** Server cap on a single breadcrumbs_by_ids request. */
export const BREADCRUMBS_BY_IDS_MAX = 200;

export interface DbStats {
  categoryCount: number;
  linkCount: number;
  pageCount: number;
  cacheHits: number;
  cacheMisses: number;
  walPending: number;
}

export interface OpLatency {
  op: number;
  p50Ns: number;
  p95Ns: number;
  p99Ns: number;
  p999Ns: number;
  maxNs: number;
  meanNs: number;
  samples: number;
}

export interface BrowseResult {
  category: Category;
  ancestors: Category[];
  children: Category[];
}

/** One node of a breadcrumb chain: id + raw (unformatted) name + slug segment. */
export interface Crumb {
  id: number;
  name: string;
  slug: string;
}

/** A search-hit link carries which field matched: 0=title, 1=url, 2=description. */
export type SearchLink = Link & {
  matchField: number;
  site: string;
  moreFromSite: number;
};

const SEARCH_SCOPE_CODE = { both: 0, links: 1, categories: 2 } as const;
const SEARCH_MODE_RANKED = 1;
const SEARCH_MODE_HYBRID = 2;

export const SEARCH_QUERY_MAX_CHARS = 256;

export const EMBEDDING_DIMS = 384;
export const MAX_VECTORS_PER_WRITE = 32;

export interface SearchResult {
  categories: Category[];
  links: SearchLink[];
  vectorUsed: boolean;
}

export const QUERY_LINKS_MAX_ROWS = 50;
export const CATEGORY_NAMES_MAX = 16;
export const CATEGORY_NAME_MAX_BYTES = 128;
export const MATCH_NAMES_MAX = 32;
export const MATCH_NAME_MAX_BYTES = 128;

export interface NameMatch {
  categoryId: number;
  namesSomeone: boolean;
}

export type NeighbourKind = "site" | "category" | "entity";

export interface Neighbour {
  label: string;
  categoryId: number;
  shared: number;
}

export interface NeighbourOf {
  categoryId?: number;
  name?: string;
  limit?: number;
}

const NEIGHBOUR_KIND_CODE: Record<NeighbourKind, number> = {
  site: 1,
  category: 2,
  entity: 3,
};
export const NEIGHBOURS_MAX = 50;
const NEIGHBOURS_DEFAULT = 8;

export type LinkQueryGroupBy =
  | "none"
  | "domain"
  | "site"
  | "host"
  | "branch"
  | "country"
  | "religion"
  | "person"
  | "org";
export type CountryEdge = "cctld" | "category" | "entity";
export const COUNTRY_EDGES: readonly CountryEdge[] = [
  "cctld",
  "category",
  "entity",
];

export interface LinkQuery {
  categoryId?: number;
  categoryNames?: readonly string[];
  wordsWithinBudget?: boolean;
  domain?: string;
  country?: string;
  via?: readonly CountryEdge[];
  hostedOnly?: boolean;
  subdomainOnly?: boolean;
  status?: LinkStatusFilter;
  words?: string;
  allWords?: boolean;
  religions?: readonly Religion[];
  entity?: string;
  groupBy?: LinkQueryGroupBy;
  groupLimit?: number;
  limit?: number;
  afterId?: number;
}

export interface LinkQueryGroup {
  label: string;
  categoryId: number;
  links: number;
  sites: number;
}

export type QueriedLink = Link & {
  site: string;
  cctldCountry: string;
  categoryCountry: string;
  entityCountries: string[];
  religions: Religion[];
};

export interface LinkQueryResult {
  ready: boolean;
  total: number;
  sites: number;
  hosts: number;
  domains: number;
  categories: number;
  groups: LinkQueryGroup[];
  links: QueriedLink[];
  nextAfterId: number;
}

export interface LinkEntities {
  religions: Religion[];
  countries: string[];
  people: string[];
  orgs: string[];
}

export interface LinkEntityWrite {
  linkId: number;
  textFingerprint: bigint;
  entities: LinkEntities;
}

export type LinkEntityWriteCode =
  | "ok"
  | "not_found"
  | "stale_text"
  | "invalid_facts";

export const MAX_ENTITY_WRITES = 64;
export const MAX_ENTITY_NAMES = 8;
export const MAX_ENTITY_NAME_BYTES = 64;

const LINK_ENTITY_WRITE_CODES: LinkEntityWriteCode[] = [
  "ok",
  "not_found",
  "stale_text",
  "invalid_facts",
];
const ENTITY_FORMAT_VERSION = 1;

const LINK_QUERY_GROUP_BY_CODE: Record<LinkQueryGroupBy, number> = {
  none: 0,
  domain: 1,
  site: 2,
  host: 3,
  branch: 4,
  country: 5,
  religion: 6,
  person: 7,
  org: 8,
};
const COUNTRY_EDGE_BIT: Record<CountryEdge, number> = {
  cctld: 1,
  category: 2,
  entity: 4,
};
const ANY_STATUS_CODE = 0xff;

function religionMask(religions: readonly Religion[]): number {
  return religions.reduce((mask, r) => mask | (1 << RELIGIONS.indexOf(r)), 0);
}

function religionsFromMask(mask: number): Religion[] {
  return RELIGIONS.filter((_, bit) => (mask & (1 << bit)) !== 0);
}

function linkQueryOptions(q: LinkQuery): bigint {
  const status = q.status === "any"
    ? ANY_STATUS_CODE
    : statusToCode(q.status ?? "approved");
  const via = (q.via ?? COUNTRY_EDGES).reduce(
    (bits, edge) => bits | COUNTRY_EDGE_BIT[edge],
    0,
  );
  const fields: Array<[value: number, bits: number]> = [
    [via, 4],
    [q.hostedOnly ? 1 : 0, 1],
    [q.allWords ? 1 : 0, 1],
    [LINK_QUERY_GROUP_BY_CODE[q.groupBy ?? "none"], 4],
    [status, 8],
    [q.groupLimit ?? 10, 8],
    [q.limit ?? 20, 8],
    [religionMask(q.religions ?? []), 16],
    [q.subdomainOnly ? 1 : 0, 1],
    [q.wordsWithinBudget ? 1 : 0, 1],
  ];
  let packed = 0n;
  let shift = 0n;
  for (const [value, bits] of fields) {
    packed |= BigInt(value) << shift;
    shift += BigInt(bits);
  }
  return packed;
}

function countryCode(r: BufferReader): string {
  const first = r.u8();
  const second = r.u8();
  return first === 0 ? "" : String.fromCharCode(first, second);
}

function encodeEntities(entities: LinkEntities): Uint8Array {
  const w = new BufferWriter()
    .u8(ENTITY_FORMAT_VERSION)
    .u16(religionMask(entities.religions))
    .u8(entities.countries.length);
  for (const code of entities.countries) w.raw(encoder.encode(code));
  for (const names of [entities.people, entities.orgs]) {
    w.u8(names.length);
    for (const name of names) {
      const bytes = encoder.encode(name);
      w.u8(bytes.length).raw(bytes);
    }
  }
  return w.build();
}

export interface QueryEmbedding {
  model: bigint;
  vector: Float32Array;
}

export interface LinkVectorWrite {
  linkId: number;
  textFingerprint: bigint;
  vector: Float32Array;
}

export interface CategoryVectorWrite {
  categoryId: number;
  vector: Float32Array;
}

export type LinkVectorWriteCode =
  | "ok"
  | "not_found"
  | "stale_text"
  | "invalid_vector";

const LINK_VECTOR_WRITE_CODES: LinkVectorWriteCode[] = [
  "ok",
  "not_found",
  "stale_text",
  "invalid_vector",
];

const FNV_OFFSET = 0xcbf29ce484222325n;
const FNV_PRIME = 0x100000001b3n;
const U64_MASK = 0xffffffffffffffffn;

export function fnv1a64(bytes: Uint8Array): bigint {
  let hash = FNV_OFFSET;
  for (const b of bytes) hash = ((hash ^ BigInt(b)) * FNV_PRIME) & U64_MASK;
  return hash;
}

export function linkTextFingerprint(
  title: string,
  description: string,
): bigint {
  const t = encoder.encode(title);
  const d = encoder.encode(description);
  const joined = new Uint8Array(t.length + 1 + d.length);
  joined.set(t);
  joined.set(d, t.length + 1);
  return fnv1a64(joined);
}

function u64Bytes(v: bigint): Uint8Array {
  const out = new Uint8Array(8);
  new DataView(out.buffer).setBigUint64(0, v, true);
  return out;
}

function f32Bytes(vector: Float32Array): Uint8Array {
  if (vector.length !== EMBEDDING_DIMS) {
    throw new Error(`embedding must have ${EMBEDDING_DIMS} dimensions`);
  }
  const out = new Uint8Array(vector.length * 4);
  const view = new DataView(out.buffer);
  vector.forEach((x, i) => view.setFloat32(i * 4, x, true));
  return out;
}

/** A cursor-paged list response: a page of links plus the cursor for the
 *  next page. `nextAfterId === 0` means there is no further page. */
export interface LinkPage {
  links: Link[];
  nextAfterId: number;
}

export interface IndexHealthEntry {
  name: string;
  primaryCount: number;
  secondaryCount: number;
  coverageBp: number;
}

export interface IndexHealthSnapshot {
  lastRunAt: number;
  indices: IndexHealthEntry[];
}

/** Parse `count` fixed-size structs from a contiguous buffer. */
const readArray = <T>(
  buf: Uint8Array,
  count: number,
  itemSize: number,
  parse: (r: BufferReader) => T,
): T[] =>
  Array.from(
    { length: count },
    (_, i) => parse(new BufferReader(buf, i * itemSize)),
  );

// ── Bitmask update builder ────────────────────────────────────

const CATEGORY_FIELD_BITS = [
  ["name", 0x01],
  ["slug", 0x02],
  ["description", 0x04],
] as const;

const LINK_FIELD_BITS = [
  ["url", 0x01],
  ["title", 0x02],
  ["description", 0x04],
] as const;

function buildBitmaskPayload(
  id: number,
  fields: Record<string, string | undefined>,
  defs: ReadonlyArray<readonly [string, number]>,
): Uint8Array {
  let mask = 0;
  const parts: Uint8Array[] = [];
  for (const [key, bit] of defs) {
    if (fields[key] !== undefined) {
      mask |= bit;
      parts.push(new BufferWriter().str(fields[key]!).build());
    }
  }
  const w = new BufferWriter().u64(id).u8(mask);
  for (const p of parts) w.raw(p);
  return w.build();
}

// ── Frame builder ─────────────────────────────────────────────

function buildFrame(
  op: number,
  flags: number,
  count: number,
  payload: Uint8Array,
): Uint8Array {
  // Request header is 8 bytes (REQUEST_HEADER_SIZE). The response will
  // come back with a 10-byte header — drainFrames() handles that asymmetry.
  const totalLen = REQUEST_HEADER_SIZE + payload.length;
  const frame = new Uint8Array(totalLen);
  const hdr = new DataView(frame.buffer);
  hdr.setUint32(0, totalLen, true);
  hdr.setUint8(4, op);
  hdr.setUint8(5, flags);
  hdr.setUint16(6, count, true);
  frame.set(payload, REQUEST_HEADER_SIZE);
  return frame;
}

// ── Internal response type ────────────────────────────────────

interface RawResponse {
  status: number;
  subStatus: number;
  count: number;
  payload: Uint8Array;
}

/** Error type thrown for non-OK responses. Carries sub_status so the
 * frontend can tailor its message (e.g. distinguishing a too-long URL
 * from an invalid slug, both of which used to collapse to "invalid"). */
export class DmozError extends Error {
  constructor(
    public readonly status: number,
    public readonly subStatus: number,
    message: string,
  ) {
    super(message);
    this.name = "DmozError";
  }
}

export function isTooBroad(e: unknown): e is DmozError {
  return e instanceof DmozError && e.subStatus === SubStatus.TooBroad;
}

// ── DmozClient ────────────────────────────────────────────────

export class DmozClient {
  private host: string;
  private port: number;
  private conn: Deno.TcpConn | null = null;
  private responseQueue: Array<{
    resolve: (v: RawResponse) => void;
    reject: (e: Error) => void;
  }> = [];
  private readBuffer: Uint8Array = new Uint8Array(0);
  private readonly requestTimeoutMs: number;
  /** Serializes all request send+queue operations so wire order matches queue order. */
  private sendChain: Promise<void> = Promise.resolve();

  constructor(
    host?: string,
    port?: number,
    requestTimeoutMs: number = REQUEST_TIMEOUT_MS,
  ) {
    this.host = host ?? Deno.env.get("DMOZDB_HOST") ?? "localhost";
    this.port = port ?? Number(Deno.env.get("DMOZDB_PORT") ?? "8080");
    this.requestTimeoutMs = requestTimeoutMs;
  }

  // ── Connection management ─────────────────────────────────

  private async ensureConnected(): Promise<Deno.TcpConn> {
    if (this.conn) return this.conn;
    try {
      const conn = await Deno.connect({
        hostname: this.host,
        port: this.port,
        transport: "tcp",
      });
      this.conn = conn;
      this.readLoop(conn);
      return conn;
    } catch (e) {
      this.conn = null;
      throw new Error(
        `Failed to connect to dmozdb at ${this.host}:${this.port}: ${e}`,
      );
    }
  }

  private disconnect() {
    if (this.conn) {
      try {
        this.conn.close();
      } catch (e) {
        console.error("Error closing connection:", e);
      }
      this.conn = null;
    }
    this.readBuffer = new Uint8Array(0);
    const pending = this.responseQueue.splice(0);
    for (const entry of pending) {
      entry.reject(new Error("connection lost"));
    }
  }

  close(): void {
    this.disconnect();
  }

  // ── Read loop ─────────────────────────────────────────────

  private async readLoop(conn: Deno.TcpConn) {
    const buf = new Uint8Array(65536);
    while (this.conn === conn) {
      let n: number | null;
      try {
        n = await conn.read(buf);
      } catch (e) {
        if (this.conn !== conn) return;
        console.error("Read loop error:", e);
        this.disconnect();
        return;
      }
      if (this.conn !== conn) return;
      if (n === null) {
        this.disconnect();
        return;
      }
      const newBuf = new Uint8Array(this.readBuffer.length + n);
      newBuf.set(this.readBuffer, 0);
      newBuf.set(buf.subarray(0, n), this.readBuffer.length);
      this.readBuffer = newBuf;
      this.drainFrames();
    }
  }

  private drainFrames() {
    while (this.readBuffer.length >= RESPONSE_HEADER_SIZE) {
      const dv = new DataView(
        this.readBuffer.buffer,
        this.readBuffer.byteOffset,
        RESPONSE_HEADER_SIZE,
      );
      const totalLen = dv.getUint32(0, true);
      if (
        totalLen < RESPONSE_HEADER_SIZE || this.readBuffer.length < totalLen
      ) {
        break;
      }

      // Response header layout (10 bytes):
      //   0..4  total_len
      //   4     op
      //   5     status
      //   6     sub_status   ← refines status; 0 on success
      //   7     reserved     ← always 0; future use
      //   8..10 count
      const status = dv.getUint8(5);
      const subStatus = dv.getUint8(6);
      // dv.getUint8(7) is reserved — always 0; not surfaced.
      const count = dv.getUint16(8, true);
      const payload = this.readBuffer.slice(RESPONSE_HEADER_SIZE, totalLen);
      this.readBuffer = this.readBuffer.slice(totalLen);

      const entry = this.responseQueue.shift();
      if (entry) {
        entry.resolve({ status, subStatus, count, payload });
      }
    }
  }

  // ── Request / response ────────────────────────────────────

  private async request(
    op: number,
    payload: Uint8Array,
    flags = 0,
    count = 0,
  ): Promise<RawResponse> {
    const frame = buildFrame(op, flags, count, payload);
    if (frame.length > REQUEST_FRAME_MAX_BYTES) {
      throw new DmozError(
        Status.Invalid,
        SubStatus.None,
        `request frame of ${frame.length} bytes exceeds the ${REQUEST_FRAME_MAX_BYTES}-byte limit`,
      );
    }

    const result = new Promise<RawResponse>((resolve, reject) => {
      this.sendChain = this.sendChain.then(async () => {
        try {
          const conn = await this.ensureConnected();
          this.responseQueue.push({ resolve, reject });
          await conn.write(frame);
        } catch (e) {
          const idx = this.responseQueue.findIndex((entry) =>
            entry.resolve === resolve
          );
          if (idx !== -1) this.responseQueue.splice(idx, 1);
          reject(e instanceof Error ? e : new Error(String(e)));
          this.disconnect();
        }
      });
    });

    return await this.settleWithin(result);
  }

  private settleWithin(result: Promise<RawResponse>): Promise<RawResponse> {
    let timer: number | undefined;
    const timeout = new Promise<never>((_resolve, reject) => {
      timer = setTimeout(() => {
        reject(
          new Error(
            `dmozdb request timed out after ${this.requestTimeoutMs}ms`,
          ),
        );
        this.disconnect();
      }, this.requestTimeoutMs);
    });
    return Promise.race([result, timeout]).finally(() => clearTimeout(timer));
  }

  private assertOk(resp: RawResponse) {
    if (resp.status !== Status.Ok) {
      const statusMsg = STATUS_MSG[resp.status] ??
        `unknown status ${resp.status}`;
      const subMsg = resp.subStatus !== SubStatus.None
        ? ` / ${SUB_STATUS_MSG[resp.subStatus] ?? `sub ${resp.subStatus}`}`
        : "";
      throw new DmozError(
        resp.status,
        resp.subStatus,
        `dmozdb error: ${statusMsg}${subMsg} (status=${resp.status} sub=${resp.subStatus})`,
      );
    }
  }

  // ── Generic helpers ───────────────────────────────────────

  private async createEntity(op: Op, payload: Uint8Array): Promise<number> {
    const resp = await this.request(op, payload, 0, 1);
    this.assertOk(resp);
    // Per-item layout: [u8 status][u8 sub_status][u64 id] = 10 bytes.
    const r = new BufferReader(resp.payload);
    const itemStatus = r.u8();
    const itemSubStatus = r.u8();
    if (itemStatus !== Status.Ok) {
      const statusMsg = STATUS_MSG[itemStatus] ?? "unknown";
      const subMsg = itemSubStatus !== SubStatus.None
        ? ` / ${SUB_STATUS_MSG[itemSubStatus] ?? `sub ${itemSubStatus}`}`
        : "";
      throw new DmozError(
        itemStatus,
        itemSubStatus,
        `dmozdb: ${statusMsg}${subMsg} (status=${itemStatus} sub=${itemSubStatus})`,
      );
    }
    return r.u64();
  }

  private async deleteEntity(op: Op, id: number): Promise<void> {
    const resp = await this.request(op, new BufferWriter().u64(id).build());
    this.assertOk(resp);
  }

  private async listEntities<T>(
    op: Op,
    payload: Uint8Array,
    itemSize: number,
    parse: (r: BufferReader) => T,
  ): Promise<T[]> {
    const resp = await this.request(op, payload);
    this.assertOk(resp);
    return readArray(resp.payload, resp.count, itemSize, parse);
  }

  /**
   * Like `listEntities` but reads the trailing `[u64 next_after_id]` cursor
   * the server appends after the `count × item` block (ops 13/16/27). The
   * count still comes from the response header, so the row block parses
   * exactly as before; the cursor is the 8 bytes immediately after it.
   */
  private listEntitiesWithCursor(
    op: Op,
    build: (afterId: number | undefined) => Uint8Array,
    afterId: number | undefined,
  ): Promise<LinkPage> {
    return this.followEmptyPages(async (pageAfterId) => {
      const resp = await this.request(op, build(pageAfterId));
      this.assertOk(resp);
      const links = readArray(resp.payload, resp.count, LINK_SIZE, readLink);
      const cursorOff = resp.count * LINK_SIZE;
      const nextAfterId = resp.payload.length >= cursorOff + 8
        ? Number(new BufferReader(resp.payload, cursorOff).u64())
        : 0;
      return { links, nextAfterId };
    }, afterId);
  }

  /** Re-asks from the cursor while a page is empty but not the last; see FILTERED_PAGE_REQUESTS_MAX. */
  private async followEmptyPages<P extends LinkPage>(
    fetchPage: (afterId: number | undefined) => Promise<P>,
    afterId: number | undefined,
  ): Promise<P> {
    let page = await fetchPage(afterId);
    for (let requests = 1; requests < FILTERED_PAGE_REQUESTS_MAX; requests++) {
      if (page.links.length > 0 || page.nextAfterId === 0) break;
      page = await fetchPage(page.nextAfterId);
    }
    return page;
  }

  /**
   * Encode the optional trailing list-extras block shared by ops 13/16/17/27:
   *   - no status, no cursor → nothing
   *   - status only          → [u8 status]
   *   - cursor (± status)    → [u8 status|0xFF][u64 after_id]
   * The 0xFF sentinel lets a cursor be requested without a status filter.
   */
  private writeListExtras(
    w: BufferWriter,
    opts: { status?: LinkStatusFilter; afterId?: number },
  ): BufferWriter {
    const status = opts.status ?? "approved";
    const code = status === "any" ? undefined : statusToCode(status);
    if (opts.afterId !== undefined) {
      w.u8(code ?? 0xFF);
      w.u64(opts.afterId);
    } else if (code !== undefined) {
      w.u8(code);
    }
    return w;
  }

  // ── Public API ────────────────────────────────────────────

  async ping(): Promise<void> {
    const resp = await this.request(Op.Ping, new Uint8Array(0));
    this.assertOk(resp);
  }

  async stats(): Promise<DbStats> {
    const resp = await this.request(Op.Stats, new Uint8Array(0));
    this.assertOk(resp);
    const r = new BufferReader(resp.payload);
    return {
      categoryCount: r.u64(),
      linkCount: r.u64(),
      pageCount: r.u64(),
      cacheHits: r.u64(),
      cacheMisses: r.u64(),
      walPending: r.u64(),
    };
  }

  async opLatency(): Promise<OpLatency[]> {
    const resp = await this.request(Op.OpLatencyStats, new Uint8Array(0));
    this.assertOk(resp);
    const r = new BufferReader(resp.payload);
    return Array.from({ length: r.u8() }, () => ({
      op: r.u8(),
      p50Ns: r.u64(),
      p95Ns: r.u64(),
      p99Ns: r.u64(),
      p999Ns: r.u64(),
      maxNs: r.u64(),
      meanNs: r.u64(),
      samples: r.u64(),
    }));
  }

  // -- Categories --

  createCategory(
    parentId: number,
    name: string,
    slug: string,
    description: string,
  ): Promise<number> {
    const payload = new BufferWriter()
      .u64(parentId)
      .str(name)
      .str(slug)
      .str(description)
      .build();
    return this.createEntity(Op.CreateCategory, payload);
  }

  async getCategory(id: number): Promise<Category> {
    const resp = await this.request(
      Op.GetCategory,
      new BufferWriter().u64(id).build(),
    );
    this.assertOk(resp);
    return readCategory(new BufferReader(resp.payload));
  }

  /**
   * Batch lookup: one RTT for up to {@link GET_CATEGORIES_BY_IDS_MAX}
   * ids. Missing ids are silently skipped — the caller diffs by reading
   * the `id` field of each returned Category. Splits oversized inputs
   * into multiple chunks transparently.
   */
  async getCategoriesByIds(ids: number[]): Promise<Category[]> {
    if (ids.length === 0) return [];
    const out: Category[] = [];
    for (let i = 0; i < ids.length; i += GET_CATEGORIES_BY_IDS_MAX) {
      const chunk = ids.slice(i, i + GET_CATEGORIES_BY_IDS_MAX);
      const w = new BufferWriter().u16(chunk.length);
      for (const id of chunk) w.u64(id);
      const resp = await this.request(Op.GetCategoriesByIds, w.build());
      this.assertOk(resp);
      const r = new BufferReader(resp.payload);
      for (let n = 0; n < resp.count; n++) out.push(readCategory(r));
    }
    return out;
  }

  /**
   * Resolve the root→leaf breadcrumb chain (inclusive of each queried id) for
   * many category ids in one call. Returns a map keyed by the requested id; an
   * unresolved id maps to an empty chain. Replaces client-side parent-chain
   * walking — the server owns hierarchy.
   */
  async breadcrumbsByIds(ids: number[]): Promise<Map<number, Crumb[]>> {
    const out = new Map<number, Crumb[]>();
    let start = 0;
    while (start < ids.length) {
      const chunk = ids.slice(start, start + BREADCRUMBS_BY_IDS_MAX);
      const w = new BufferWriter().u16(chunk.length);
      for (const id of chunk) w.u64(id);
      const resp = await this.request(Op.BreadcrumbsByIds, w.build());
      this.assertOk(resp);
      if (resp.count === 0) {
        throw new Error("breadcrumbsByIds: one chain exceeds the reply buffer");
      }
      start += resp.count;
      const r = new BufferReader(resp.payload);
      for (let g = 0; g < resp.count; g++) {
        const len = r.u16();
        const chain: Crumb[] = [];
        for (let c = 0; c < len; c++) {
          chain.push({
            id: r.u64(),
            name: r.fixedString(64),
            slug: r.fixedString(128),
          });
        }
        out.set(chunk[g], chain);
      }
    }
    return out;
  }

  async updateCategory(
    id: number,
    fields: { name?: string; slug?: string; description?: string },
  ): Promise<void> {
    const payload = buildBitmaskPayload(id, fields, CATEGORY_FIELD_BITS);
    const resp = await this.request(Op.UpdateCategory, payload);
    this.assertOk(resp);
  }

  deleteCategory(id: number): Promise<void> {
    return this.deleteEntity(Op.DeleteCategory, id);
  }

  async moveCategory(id: number, newParentId: number): Promise<void> {
    const payload = new BufferWriter().u64(id).u64(newParentId).build();
    const resp = await this.request(Op.MoveCategory, payload);
    this.assertOk(resp);
  }

  listRootCategories(offset = 0, limit = 100): Promise<Category[]> {
    return this.listEntities(
      Op.ListRootCategories,
      new BufferWriter().u32(offset).u32(limit).build(),
      CATEGORY_SIZE,
      readCategory,
    );
  }

  listChildren(
    parentId: number,
    offset = 0,
    limit = 100,
  ): Promise<Category[]> {
    return this.listEntities(
      Op.ListChildren,
      new BufferWriter().u64(parentId).u32(offset).u32(limit).build(),
      CATEGORY_SIZE,
      readCategory,
    );
  }

  // -- Links --

  createLink(
    categoryId: number,
    url: string,
    title: string,
    description: string,
  ): Promise<number> {
    const payload = new BufferWriter()
      .u64(categoryId)
      .str(url)
      .str(title)
      .str(description)
      .build();
    return this.createEntity(Op.CreateLink, payload);
  }

  /** Submit a link as a non-admin user. The new record lands with
   * `status = pending` and `submitter_id = submitterId`. Admins
   * approve it later via `updateLinkStatus`. */
  createSubmission(
    categoryId: number,
    url: string,
    title: string,
    description: string,
    submitterId: number,
  ): Promise<number> {
    const payload = new BufferWriter()
      .u64(categoryId)
      .str(url)
      .str(title)
      .str(description)
      .u64(submitterId)
      .build();
    return this.createEntity(Op.CreateSubmission, payload);
  }

  /** Flip a link's editorial status. `status` must be one of
   * "pending" (0), "approved" (1), "rejected" (2). */
  async updateLinkStatus(id: number, status: LinkStatus): Promise<void> {
    const code = status === "pending" ? 0 : status === "approved" ? 1 : 2;
    const payload = new BufferWriter().u64(id).u8(code).build();
    const resp = await this.request(Op.UpdateLinkStatus, payload);
    this.assertOk(resp);
  }

  /**
   * Move a link to a different category. Server op = 28 (MoveLink).
   * Throws on LinkNotFound or CategoryNotFound.
   */
  async moveLink(id: number, newCategoryId: number): Promise<void> {
    const payload = new BufferWriter().u64(id).u64(newCategoryId).build();
    const resp = await this.request(Op.MoveLink, payload);
    this.assertOk(resp);
  }

  async getLink(id: number): Promise<Link> {
    const resp = await this.request(
      Op.GetLink,
      new BufferWriter().u64(id).build(),
    );
    this.assertOk(resp);
    return readLink(new BufferReader(resp.payload));
  }

  async updateLink(
    id: number,
    fields: { url?: string; title?: string; description?: string },
  ): Promise<void> {
    const payload = buildBitmaskPayload(id, fields, LINK_FIELD_BITS);
    const resp = await this.request(Op.UpdateLink, payload);
    this.assertOk(resp);
  }

  deleteLink(id: number): Promise<void> {
    return this.deleteEntity(Op.DeleteLink, id);
  }

  listLinks(
    categoryId: number,
    opts: {
      offset?: number;
      limit?: number;
      status?: LinkStatusFilter;
      afterId?: number;
    } = {},
  ): Promise<LinkPage> {
    const offset = opts.offset ?? 0;
    const limit = opts.limit ?? 100;
    return this.listEntitiesWithCursor(Op.ListLinks, (afterId) => {
      const w = new BufferWriter().u64(categoryId).u32(offset).u32(limit);
      return this.writeListExtras(w, { status: opts.status, afterId }).build();
    }, opts.afterId);
  }

  listAllLinks(
    opts: {
      offset?: number;
      limit?: number;
      status?: LinkStatusFilter;
      afterId?: number;
    } = {},
  ): Promise<LinkPage> {
    const offset = opts.offset ?? 0;
    const limit = opts.limit ?? 12;
    return this.listEntitiesWithCursor(Op.ListAllLinks, (afterId) => {
      const w = new BufferWriter().u32(offset).u32(limit);
      return this.writeListExtras(w, { status: opts.status, afterId }).build();
    }, opts.afterId);
  }

  listMySubmissions(
    submitterId: number,
    opts: {
      offset?: number;
      limit?: number;
      status?: LinkStatusFilter;
      afterId?: number;
    } = {},
  ): Promise<LinkPage> {
    const offset = opts.offset ?? 0;
    const limit = opts.limit ?? 100;
    return this.listEntitiesWithCursor(Op.ListLinksBySubmitter, (afterId) => {
      const w = new BufferWriter().u64(submitterId).u32(offset).u32(limit);
      return this.writeListExtras(w, { status: opts.status, afterId }).build();
    }, opts.afterId);
  }

  /**
   * Subtree link page (op=17). `total` is the subtree's exact link count for
   * `opts.status` (approved unless set), or over every status for "any".
   */
  listSubtreeLinks(
    categoryId: number,
    opts: {
      order?: number;
      offset?: number;
      limit?: number;
      status?: LinkStatusFilter;
      afterId?: number;
    } = {},
  ): Promise<{ links: Link[]; total: number; nextAfterId: number }> {
    const order = opts.order ?? 0;
    const offset = opts.offset ?? 0;
    const limit = opts.limit ?? 50;
    return this.followEmptyPages(async (afterId) => {
      const w = new BufferWriter()
        .u64(categoryId)
        .u8(order)
        .u32(offset)
        .u32(limit);
      this.writeListExtras(w, { status: opts.status, afterId });
      const resp = await this.request(Op.ListSubtreeLinks, w.build());
      this.assertOk(resp);

      const r = new BufferReader(resp.payload);
      const count = r.u32();
      const links = readArray(
        resp.payload.subarray(r.offset),
        count,
        LINK_SIZE,
        readLink,
      );
      r.skip(count * LINK_SIZE);
      const total = Number(r.u64());
      // Trailing cursor (appended after total); older servers omit it.
      const nextAfterId = resp.payload.length >= r.offset + 8
        ? Number(r.u64())
        : 0;
      return { links, total, nextAfterId };
    }, opts.afterId);
  }

  // -- Integrity / index health --

  async indexHealth(): Promise<IndexHealthSnapshot> {
    const resp = await this.request(Op.IndexHealth, new Uint8Array());
    this.assertOk(resp);
    return parseIndexHealth(resp.payload);
  }

  async runVerifier(): Promise<IndexHealthSnapshot> {
    const resp = await this.request(Op.RunVerifier, new Uint8Array());
    this.assertOk(resp);
    return parseIndexHealth(resp.payload);
  }

  async rebuildIndex(
    name: string,
  ): Promise<{ entriesInserted: number; elapsedMs: number }> {
    const w = new BufferWriter();
    const bytes = encoder.encode(name);
    w.u8(bytes.length);
    w.raw(bytes);
    const resp = await this.request(Op.RebuildIndex, w.build());
    this.assertOk(resp);
    const r = new BufferReader(resp.payload);
    const entriesInserted = Number(r.u64());
    const elapsedMs = r.u32();
    return { entriesInserted, elapsedMs };
  }

  // -- Browse & Search --

  async browsePathIfFound(path: string): Promise<BrowseResult | undefined> {
    try {
      return await this.browsePath(path);
    } catch (e) {
      if (e instanceof DmozError && e.status === Status.NotFound) {
        return undefined;
      }
      throw e;
    }
  }

  async browsePath(path: string): Promise<BrowseResult> {
    const resp = await this.request(
      Op.BrowsePath,
      new BufferWriter().str(path).build(),
    );
    this.assertOk(resp);

    const r = new BufferReader(resp.payload);
    const category = readCategory(r);

    const ancestorCount = r.u16();
    const ancestors = readArray(
      resp.payload.subarray(r.offset),
      ancestorCount,
      CATEGORY_SIZE,
      readCategory,
    );
    r.skip(ancestorCount * CATEGORY_SIZE);

    const childCount = r.u16();
    const children = readArray(
      resp.payload.subarray(r.offset),
      childCount,
      CATEGORY_SIZE,
      readCategory,
    );
    r.skip(childCount * CATEGORY_SIZE);

    return { category, ancestors, children };
  }

  async search(
    query: string,
    opts: {
      limit?: number;
      scope?: "both" | "links" | "categories";
      mode?: "all_terms" | "ranked";
      queryEmbedding?: QueryEmbedding;
      capPerSite?: boolean;
      status?: LinkStatusFilter;
    } = {},
  ): Promise<SearchResult> {
    const limit = opts.limit ?? 20;
    const w = new BufferWriter().str(query).u32(limit);
    const scope = SEARCH_SCOPE_CODE[opts.scope ?? "both"];
    const embedding = opts.queryEmbedding;
    const ranked = embedding !== undefined || opts.mode === "ranked";
    const capPerSite = ranked && opts.capPerSite === true;
    if (embedding) {
      w.u8(scope).u8(SEARCH_MODE_HYBRID).raw(u64Bytes(embedding.model)).raw(
        f32Bytes(embedding.vector),
      );
    } else if (opts.mode === "ranked") w.u8(scope).u8(SEARCH_MODE_RANKED);
    else if (scope !== SEARCH_SCOPE_CODE.both) w.u8(scope);
    if (capPerSite) w.u8(1);
    const resp = await this.request(Op.Search, w.build());
    this.assertOk(resp);

    const r = new BufferReader(resp.payload);

    const catCount = r.u16();
    const categories = readArray(
      resp.payload.subarray(r.offset),
      catCount,
      CATEGORY_SIZE,
      readCategory,
    );
    r.skip(catCount * CATEGORY_SIZE);

    const linkCount = r.u16();
    const links: SearchLink[] = [];
    for (let i = 0; i < linkCount; i++) {
      const link = readLink(new BufferReader(resp.payload, r.offset));
      r.skip(LINK_SIZE);
      const matchField = r.u8();
      const site = capPerSite ? r.str() : "";
      const moreFromSite = capPerSite ? r.u16() : 0;
      links.push({ ...link, matchField, site, moreFromSite });
    }

    const vectorUsed = embedding !== undefined && r.u8() === 1;
    const status = opts.status ?? "approved";
    const visible = status === "any"
      ? links
      : links.filter((link) => link.status === status);
    return { categories, links: visible, vectorUsed };
  }

  async matchNames(phrases: readonly string[]): Promise<NameMatch[] | null> {
    const w = new BufferWriter().u16(phrases.length);
    for (const phrase of phrases) w.str(phrase);
    const resp = await this.request(Op.MatchNames, w.build());
    this.assertOk(resp);

    const r = new BufferReader(resp.payload);
    const ready = r.u8() === 1;
    const matches = Array.from({ length: r.u16() }, () => ({
      categoryId: r.u64(),
      namesSomeone: r.u8() === 1,
    }));
    return ready ? matches : null;
  }

  async queryLinks(q: LinkQuery = {}): Promise<LinkQueryResult> {
    const w = new BufferWriter()
      .u64(q.categoryId ?? 0)
      .str(q.domain ?? "")
      .str(q.country ?? "")
      .raw(u64Bytes(linkQueryOptions(q)))
      .str(q.words ?? "")
      .str(q.entity ?? "")
      .u64(q.afterId ?? 0);

    const names = q.categoryNames ?? [];
    if (names.length > 0) {
      w.u8(names.length);
      for (const name of names) w.str(name);
    }

    const resp = await this.request(Op.QueryLinks, w.build());
    this.assertOk(resp);

    const r = new BufferReader(resp.payload);
    const ready = r.u8() === 1;
    const total = r.u64();
    const sites = r.u64();
    const hosts = r.u64();
    const domains = r.u64();
    const groups = Array.from({ length: r.u16() }, () => ({
      label: r.str(),
      categoryId: r.u64(),
      links: r.u64(),
      sites: r.u64(),
    }));

    const linkCount = r.u16();
    const links: QueriedLink[] = [];
    for (let i = 0; i < linkCount; i++) {
      const link = readLink(new BufferReader(resp.payload, r.offset));
      r.skip(LINK_SIZE);
      const site = r.str();
      const cctldCountry = countryCode(r);
      const categoryCountry = countryCode(r);
      const religions = religionsFromMask(r.u16());
      const entityCountries = Array.from(
        { length: r.u8() },
        () => countryCode(r),
      );
      links.push({
        ...link,
        site,
        cctldCountry,
        categoryCountry,
        entityCountries,
        religions,
      });
    }

    const nextAfterId = r.u64();
    const hasCategories = resp.payload.length - r.offset >= 8;
    return {
      ready,
      total,
      sites,
      hosts,
      domains,
      categories: hasCategories ? r.u64() : 0,
      groups,
      links,
      nextAfterId,
    };
  }

  async neighbours(
    kind: NeighbourKind,
    of: NeighbourOf,
  ): Promise<Neighbour[] | null> {
    const w = new BufferWriter()
      .u32(NEIGHBOUR_KIND_CODE[kind])
      .u32(of.limit ?? NEIGHBOURS_DEFAULT)
      .u64(of.categoryId ?? 0)
      .str(of.name ?? "");
    const resp = await this.request(Op.Neighbours, w.build());
    this.assertOk(resp);

    const r = new BufferReader(resp.payload);
    const ready = r.u8() === 1;
    const neighbours = Array.from({ length: r.u16() }, () => ({
      label: r.str(),
      categoryId: r.u64(),
      shared: r.u32(),
    }));
    return ready ? neighbours : null;
  }

  async putLinkEntities(
    writes: LinkEntityWrite[],
  ): Promise<Array<{ linkId: number; code: LinkEntityWriteCode }>> {
    if (writes.length === 0) return [];
    if (writes.length > MAX_ENTITY_WRITES) {
      throw new Error(`putLinkEntities: cap is ${MAX_ENTITY_WRITES}`);
    }
    const w = new BufferWriter().u16(writes.length);
    for (const item of writes) {
      const facts = encodeEntities(item.entities);
      w.u64(item.linkId).raw(u64Bytes(item.textFingerprint)).u16(facts.length)
        .raw(facts);
    }
    const resp = await this.request(Op.PutLinkEntities, w.build());
    this.assertOk(resp);

    const r = new BufferReader(resp.payload);
    const total = r.u16() + r.u16();
    return Array.from({ length: total }, () => ({
      linkId: Number(r.u64()),
      code: LINK_ENTITY_WRITE_CODES[r.u8()] ?? "invalid_facts",
    }));
  }

  async putLinkVectors(
    model: bigint,
    writes: LinkVectorWrite[],
  ): Promise<Array<{ linkId: number; code: LinkVectorWriteCode }>> {
    if (writes.length === 0) return [];
    if (writes.length > MAX_VECTORS_PER_WRITE) {
      throw new Error(`putLinkVectors: cap is ${MAX_VECTORS_PER_WRITE}`);
    }
    const w = new BufferWriter().raw(u64Bytes(model)).u16(writes.length);
    for (const item of writes) {
      w.u64(item.linkId).raw(u64Bytes(item.textFingerprint)).raw(
        f32Bytes(item.vector),
      );
    }
    const resp = await this.request(Op.PutLinkVectors, w.build());
    this.assertOk(resp);

    const r = new BufferReader(resp.payload);
    const total = r.u16() + r.u16();
    return Array.from({ length: total }, () => ({
      linkId: Number(r.u64()),
      code: LINK_VECTOR_WRITE_CODES[r.u8()] ?? "invalid_vector",
    }));
  }

  async putCategoryVectors(
    model: bigint,
    writes: CategoryVectorWrite[],
  ): Promise<Array<{ categoryId: number; code: LinkVectorWriteCode }>> {
    if (writes.length === 0) return [];
    if (writes.length > MAX_VECTORS_PER_WRITE) {
      throw new Error(`putCategoryVectors: cap is ${MAX_VECTORS_PER_WRITE}`);
    }
    const w = new BufferWriter().raw(u64Bytes(model)).u16(writes.length);
    for (const item of writes) {
      w.u64(item.categoryId).raw(f32Bytes(item.vector));
    }
    const resp = await this.request(Op.PutCategoryVectors, w.build());
    this.assertOk(resp);

    const r = new BufferReader(resp.payload);
    const total = r.u16() + r.u16();
    return Array.from({ length: total }, () => ({
      categoryId: Number(r.u64()),
      code: LINK_VECTOR_WRITE_CODES[r.u8()] ?? "invalid_vector",
    }));
  }

  /**
   * Flip the status of up to 200 links in one round-trip (op=34). Returns
   * the count that changed plus a per-id error list (code: 1=not_found,
   * 2=already_in_state, 3=invalid_transition).
   */
  async bulkUpdateLinkStatus(
    ids: number[],
    status: LinkStatus,
  ): Promise<{ ok: number; errors: Array<{ id: number; code: number }> }> {
    if (ids.length === 0) return { ok: 0, errors: [] };
    if (ids.length > 200) throw new Error("bulkUpdateLinkStatus: cap is 200");
    const w = new BufferWriter().u8(statusToCode(status)).u16(ids.length);
    for (const id of ids) w.u64(id);
    const resp = await this.request(Op.BulkUpdateLinkStatus, w.build());
    this.assertOk(resp);
    return parseBulkResponse(resp.payload);
  }

  /**
   * Delete up to 200 links in one round-trip (op=35). Returns the count
   * deleted plus a per-id error list (code: 1=not_found).
   */
  async bulkDeleteLinks(
    ids: number[],
  ): Promise<{ ok: number; errors: Array<{ id: number; code: number }> }> {
    if (ids.length === 0) return { ok: 0, errors: [] };
    if (ids.length > 200) throw new Error("bulkDeleteLinks: cap is 200");
    const w = new BufferWriter().u16(ids.length);
    for (const id of ids) w.u64(id);
    const resp = await this.request(Op.BulkDeleteLinks, w.build());
    this.assertOk(resp);
    return parseBulkResponse(resp.payload);
  }

  /** One-round-trip per-status link totals for the admin chip strip (op=36). */
  async countsByStatus(): Promise<
    { pending: number; approved: number; rejected: number }
  > {
    const resp = await this.request(Op.CountsByStatus, new Uint8Array());
    this.assertOk(resp);
    const r = new BufferReader(resp.payload);
    return {
      pending: Number(r.u64()),
      approved: Number(r.u64()),
      rejected: Number(r.u64()),
    };
  }
}

/** Parse `[u16 ok][u16 err][[u64 id][u8 code]…]` from a bulk-op response. */
function parseBulkResponse(
  payload: Uint8Array,
): { ok: number; errors: Array<{ id: number; code: number }> } {
  const r = new BufferReader(payload);
  const okCount = r.u16();
  const errCount = r.u16();
  const errors: Array<{ id: number; code: number }> = [];
  const total = okCount + errCount;
  for (let i = 0; i < total; i++) {
    const id = Number(r.u64());
    const code = r.u8();
    if (code !== 0) errors.push({ id, code });
  }
  return { ok: okCount, errors };
}

// ── Index health parser ───────────────────────────────────────

function parseIndexHealth(payload: Uint8Array): IndexHealthSnapshot {
  const r = new BufferReader(payload);
  const lastRunAt = Number(r.i64());
  const count = r.u8();
  const indices: IndexHealthEntry[] = [];
  for (let i = 0; i < count; i++) {
    const nameLen = r.u8();
    const name = decoder.decode(payload.subarray(r.offset, r.offset + nameLen));
    r.skip(nameLen);
    const primaryCount = Number(r.u64());
    const secondaryCount = Number(r.u64());
    const coverageBp = r.u32();
    indices.push({ name, primaryCount, secondaryCount, coverageBp });
  }
  return { lastRunAt, indices };
}

// ── Singleton ─────────────────────────────────────────────────

let _client: DmozClient | null = null;

/**
 * Returns a shared DmozClient instance. Uses DMOZDB_HOST and DMOZDB_PORT
 * environment variables, defaulting to localhost:8080.
 */
export function getClient(): DmozClient {
  if (!_client) {
    _client = new DmozClient();
  }
  return _client;
}
