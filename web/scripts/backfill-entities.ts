import {
  getClient,
  type LinkEntityWrite,
  linkTextFingerprint,
  MAX_ENTITY_WRITES,
} from "../lib/dmoz-client.ts";
import { extractEntities } from "../lib/entities.ts";

const PROGRESS_EVERY_PAGES = 50;
const CONCURRENCY = 4;

const client = getClient();
const dumpPath = Deno.env.get("BACKFILL_DUMP");
const dump = dumpPath
  ? await Deno.open(dumpPath, { create: true, write: true, truncate: true })
  : undefined;
const encoder = new TextEncoder();
const counts = new Map<string, number>();
const started = performance.now();
let afterId = Number(Deno.env.get("BACKFILL_AFTER_ID") ?? 0);
let pages = 0;

async function inBatches<T, R>(
  items: T[],
  size: number,
  fn: (item: T) => Promise<R>,
): Promise<R[]> {
  const out: R[] = [];
  for (let i = 0; i < items.length; i += size) {
    out.push(...await Promise.all(items.slice(i, i + size).map(fn)));
  }
  return out;
}

do {
  const page = await client.listAllLinks({ afterId, limit: MAX_ENTITY_WRITES });
  const writes: LinkEntityWrite[] = await inBatches(
    page.links,
    CONCURRENCY,
    async (link) => ({
      linkId: link.id,
      textFingerprint: linkTextFingerprint(link.title, link.description),
      entities: await extractEntities(link.title, link.description),
    }),
  );

  for (const { code } of await client.putLinkEntities(writes)) {
    counts.set(code, (counts.get(code) ?? 0) + 1);
  }
  if (dump) {
    const rows = writes.map((w) =>
      JSON.stringify({ id: w.linkId, ...w.entities })
    );
    await dump.write(encoder.encode(rows.join("\n") + "\n"));
  }

  afterId = page.nextAfterId;
  if (++pages % PROGRESS_EVERY_PAGES === 0) {
    console.log(JSON.stringify({ afterId, ...Object.fromEntries(counts) }));
  }
} while (afterId !== 0);

dump?.close();
console.log(JSON.stringify({
  seconds: Math.round((performance.now() - started) / 1000),
  results: Object.fromEntries(counts),
}));
Deno.exit(0);
