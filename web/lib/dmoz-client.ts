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
  Status,
  STATUS_MSG,
  statusToCode,
  SUB_STATUS_MSG,
  SubStatus,
} from "./dmoz-protocol.gen.ts";

export { type Category, type Link, type LinkStatus, Op, Status, SubStatus };
export { linkStatusFromByte } from "./dmoz-protocol.gen.ts";

const REQUEST_HEADER_SIZE = 8;
const RESPONSE_HEADER_SIZE = 10;
const REQUEST_TIMEOUT_MS = 10_000;

/** Server cap on a single get_categories_by_ids request. */
export const GET_CATEGORIES_BY_IDS_MAX = 200;

/** Server cap on a single breadcrumbs_by_ids request. */
export const BREADCRUMBS_BY_IDS_MAX = 200;

/** Bit 0 of Category.flags: category was reattached after orphan recovery. */
export const FLAG_ORPHAN_RECOVERED = 0x01;

export function isOrphanRecovered(c: Category): boolean {
  return (c.flags & FLAG_ORPHAN_RECOVERED) !== 0;
}

export interface DbStats {
  categoryCount: number;
  linkCount: number;
  pageCount: number;
  cacheHits: number;
  cacheMisses: number;
  walPending: number;
}

export interface BrowseResult {
  category: Category;
  ancestors: Category[];
  children: Category[];
  totalLinksInSubtree: number;
}

/** One node of a breadcrumb chain: id + raw (unformatted) name + slug segment. */
export interface Crumb {
  id: number;
  name: string;
  slug: string;
}

/** A search-hit link carries which field matched: 0=title, 1=url, 2=description. */
export type SearchLink = Link & { matchField: number };

export interface SearchResult {
  categories: Category[];
  links: SearchLink[];
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
  private readLoopRunning = false;
  /** Serializes all request send+queue operations so wire order matches queue order. */
  private sendChain: Promise<void> = Promise.resolve();

  constructor(host?: string, port?: number) {
    this.host = host ?? Deno.env.get("DMOZDB_HOST") ?? "localhost";
    this.port = port ?? Number(Deno.env.get("DMOZDB_PORT") ?? "8080");
  }

  // ── Connection management ─────────────────────────────────

  private async ensureConnected(): Promise<Deno.TcpConn> {
    if (this.conn) return this.conn;
    try {
      this.conn = await Deno.connect({
        hostname: this.host,
        port: this.port,
        transport: "tcp",
      });
      this.startReadLoop();
      return this.conn;
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
    this.readLoopRunning = false;
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

  private startReadLoop() {
    if (this.readLoopRunning) return;
    this.readLoopRunning = true;
    this.readLoop();
  }

  private async readLoop() {
    const buf = new Uint8Array(65536);
    while (this.readLoopRunning && this.conn) {
      let n: number | null;
      try {
        n = await this.conn.read(buf);
      } catch (e) {
        console.error("Read loop error:", e);
        this.disconnect();
        return;
      }
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

  private request(
    op: number,
    payload: Uint8Array,
    flags = 0,
    count = 0,
  ): Promise<RawResponse> {
    const frame = buildFrame(op, flags, count, payload);

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

    return Promise.race([
      result,
      new Promise<never>((_resolve, reject) => {
        setTimeout(
          () => reject(new Error("dmozdb request timed out after 10s")),
          REQUEST_TIMEOUT_MS,
        );
      }),
    ]);
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
  private async listEntitiesWithCursor(
    op: Op,
    payload: Uint8Array,
    itemSize: number,
    parse: (r: BufferReader) => Link,
  ): Promise<LinkPage> {
    const resp = await this.request(op, payload);
    this.assertOk(resp);
    const links = readArray(resp.payload, resp.count, itemSize, parse);
    const cursorOff = resp.count * itemSize;
    const nextAfterId = resp.payload.length >= cursorOff + 8
      ? Number(new BufferReader(resp.payload, cursorOff).u64())
      : 0;
    return { links, nextAfterId };
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
    opts: { status?: LinkStatus; afterId?: number },
  ): BufferWriter {
    if (opts.afterId !== undefined) {
      w.u8(opts.status !== undefined ? statusToCode(opts.status) : 0xFF);
      w.u64(opts.afterId);
    } else if (opts.status !== undefined) {
      w.u8(statusToCode(opts.status));
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
    for (let i = 0; i < ids.length; i += BREADCRUMBS_BY_IDS_MAX) {
      const chunk = ids.slice(i, i + BREADCRUMBS_BY_IDS_MAX);
      const w = new BufferWriter().u16(chunk.length);
      for (const id of chunk) w.u64(id);
      const resp = await this.request(Op.BreadcrumbsByIds, w.build());
      this.assertOk(resp);
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

  /**
   * Per-category link page (op=13). When `opts.status` is set, the server
   * walks `link_by_category` and filters by status — sees rows past the
   * first 100 that would be hidden by a JS-side post-filter.
   */
  listLinks(
    categoryId: number,
    opts: {
      offset?: number;
      limit?: number;
      status?: LinkStatus;
      afterId?: number;
    } = {},
  ): Promise<LinkPage> {
    const offset = opts.offset ?? 0;
    const limit = opts.limit ?? 100;
    const w = new BufferWriter().u64(categoryId).u32(offset).u32(limit);
    this.writeListExtras(w, opts);
    return this.listEntitiesWithCursor(
      Op.ListLinks,
      w.build(),
      LINK_SIZE,
      readLink,
    );
  }

  /**
   * Whole-DB link page ordered by link id (op=16). When `opts.status` is
   * set, the server scans `links_by_id` and applies the status filter so
   * the admin moderation queue sees pending rows past the page window.
   */
  listAllLinks(
    opts: {
      offset?: number;
      limit?: number;
      status?: LinkStatus;
      afterId?: number;
    } = {},
  ): Promise<LinkPage> {
    const offset = opts.offset ?? 0;
    const limit = opts.limit ?? 12;
    const w = new BufferWriter().u32(offset).u32(limit);
    this.writeListExtras(w, opts);
    return this.listEntitiesWithCursor(
      Op.ListAllLinks,
      w.build(),
      LINK_SIZE,
      readLink,
    );
  }

  /**
   * Per-submitter link page (op=27). When `opts.status` is set, the
   * server filters the per-user secondary index so the dashboard's
   * per-tab counts and listings stay correct past 100 submissions.
   */
  listMySubmissions(
    submitterId: number,
    opts: {
      offset?: number;
      limit?: number;
      status?: LinkStatus;
      afterId?: number;
    } = {},
  ): Promise<LinkPage> {
    const offset = opts.offset ?? 0;
    const limit = opts.limit ?? 100;
    const w = new BufferWriter().u64(submitterId).u32(offset).u32(limit);
    this.writeListExtras(w, opts);
    return this.listEntitiesWithCursor(
      Op.ListLinksBySubmitter,
      w.build(),
      LINK_SIZE,
      readLink,
    );
  }

  /**
   * Subtree link page (op=17). When `opts.status` is set, the server
   * walks the full descendant link set, filters by status, and returns
   * the paged matches plus the *filtered* total across the whole subtree.
   */
  async listSubtreeLinks(
    categoryId: number,
    opts: {
      order?: number;
      offset?: number;
      limit?: number;
      status?: LinkStatus;
      afterId?: number;
    } = {},
  ): Promise<{ links: Link[]; total: number; nextAfterId: number }> {
    const order = opts.order ?? 0;
    const offset = opts.offset ?? 0;
    const limit = opts.limit ?? 50;
    const w = new BufferWriter()
      .u64(categoryId)
      .u8(order)
      .u32(offset)
      .u32(limit);
    this.writeListExtras(w, opts);
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

    const totalLinksInSubtree = Number(r.u64());

    return { category, ancestors, children, totalLinksInSubtree };
  }

  async search(
    query: string,
    opts: { limit?: number; scope?: "both" | "links" | "categories" } = {},
  ): Promise<SearchResult> {
    const limit = opts.limit ?? 20;
    const w = new BufferWriter().str(query).u32(limit);
    if (opts.scope === "links") w.u8(1);
    else if (opts.scope === "categories") w.u8(2);
    // scope=both (default) → omit the byte; the server treats absent as both.
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

    // New per-row layout: [Link struct][u8 match_field].
    const linkCount = r.u16();
    const links: SearchLink[] = [];
    for (let i = 0; i < linkCount; i++) {
      const link = readLink(new BufferReader(resp.payload, r.offset));
      r.skip(LINK_SIZE);
      const matchField = r.u8();
      links.push({ ...link, matchField });
    }

    return { categories, links };
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
