import { assertEquals } from "jsr:@std/assert@^1";
import { getClient } from "../../../lib/dmoz-client.ts";
import {
  CATEGORY_SIZE,
  LINK_SIZE,
  Op,
} from "../../../lib/dmoz-protocol.gen.ts";
import {
  type FakeFrame,
  responseFrame,
  startFakeBackend,
} from "../../../lib/dmoz-fake-backend.ts";
import { handler as browseApi } from "../../api/v1/browse.ts";
import { handler as categoryLinksApi } from "../../api/v1/categories/[id]/links.ts";
import { call } from "../../api/v1/_lib/route_call.ts";
import { pageCount } from "../../../lib/format.ts";

const PAGE_SIZE = 50;
const MAX_PAGES = 101;

const FILED = { approved: 120, pending: 40, rejected: 30 };
const FILED_IN_ANY_STATUS = 190;
const STATUS_CODE = { pending: 0, approved: 1, rejected: 2 } as const;
const COUNT_OFFSETS = {
  approved: CATEGORY_SIZE - 36,
  subtree: CATEGORY_SIZE - 16,
  pending: CATEGORY_SIZE - 4,
};

function categoryBytes(): Uint8Array {
  const bytes = new Uint8Array(CATEGORY_SIZE);
  const view = new DataView(bytes.buffer);
  view.setBigUint64(0, 7n, true);
  view.setUint32(COUNT_OFFSETS.approved, FILED.approved, true);
  view.setBigUint64(COUNT_OFFSETS.subtree, BigInt(FILED_IN_ANY_STATUS), true);
  view.setUint32(COUNT_OFFSETS.pending, FILED.pending, true);
  return bytes;
}

function browseReply(): Uint8Array {
  const payload = new Uint8Array(CATEGORY_SIZE + 2 + 2 + 8);
  payload.set(categoryBytes());
  return responseFrame(Op.BrowsePath, payload);
}

function subtreePageReply(frame: FakeFrame): Uint8Array {
  const view = new DataView(
    frame.payload.buffer,
    frame.payload.byteOffset,
    frame.payload.length,
  );
  const offset = view.getUint32(9, true);
  const limit = view.getUint32(13, true);
  const status = frame.payload.length > 17
    ? Object.entries(STATUS_CODE).find(([, code]) => code === frame.payload[17])
    : undefined;
  const total = status
    ? FILED[status[0] as keyof typeof FILED]
    : FILED_IN_ANY_STATUS;
  const written = Math.max(0, Math.min(limit, total - offset));

  const payload = new Uint8Array(4 + written * LINK_SIZE + 16);
  const out = new DataView(payload.buffer);
  out.setUint32(0, written, true);
  out.setBigUint64(4 + written * LINK_SIZE, BigInt(total), true);
  return responseFrame(Op.ListSubtreeLinks, payload);
}

function serveSubtree(frame: FakeFrame): Uint8Array {
  return frame.op === Op.BrowsePath ? browseReply() : subtreePageReply(frame);
}

Deno.test("a subtree with pending and rejected links shows the approved count everywhere the public sees it", async (t) => {
  const backend = startFakeBackend(serveSubtree);
  Deno.env.set("DMOZDB_HOST", "127.0.0.1");
  Deno.env.set("DMOZDB_PORT", String(backend.port));
  const client = getClient();

  try {
    await t.step(
      "the filtered listing's total is the approved count",
      async () => {
        const page = await client.listSubtreeLinks(7, { limit: PAGE_SIZE });
        const browsed = await client.browsePath("arts");

        assertEquals(page.total, FILED.approved);
        assertEquals(browsed.category.linkCountSubtreeApproved, FILED.approved);
        assertEquals(browsed.category.linkCountSubtree, FILED_IN_ANY_STATUS);
      },
    );

    await t.step(
      "the API reports approved counts for a category and its links page",
      async () => {
        const browse = await call(browseApi, "/api/v1/browse?path=arts");
        const browsed = browse.body as unknown as {
          category: { linkCountSubtree: number };
          totalLinksInSubtree: number;
        };
        const links = await call(
          categoryLinksApi,
          "/api/v1/categories/7/links",
          {
            id: "7",
          },
        );

        assertEquals(browsed.category.linkCountSubtree, FILED.approved);
        assertEquals(browsed.totalLinksInSubtree, FILED.approved);
        assertEquals(
          (links.body as unknown as { total: number }).total,
          FILED.approved,
        );
      },
    );

    await t.step("the pager's last page lists links", async () => {
      const first = await client.listSubtreeLinks(7, { limit: PAGE_SIZE });
      const pages = pageCount(first.total, PAGE_SIZE, MAX_PAGES);
      const last = await client.listSubtreeLinks(7, {
        offset: (pages - 1) * PAGE_SIZE,
        limit: PAGE_SIZE,
      });

      assertEquals(pages, 3);
      assertEquals(last.links.length, FILED.approved - (pages - 1) * PAGE_SIZE);
    });
  } finally {
    client.close();
    await backend.close();
  }
});
