import {
  getClient,
  linkTextFingerprint,
  type LinkVectorWrite,
  MAX_VECTORS_PER_WRITE,
} from "../lib/dmoz-client.ts";
import {
  EMBEDDING_MODEL,
  embedText,
  linkDocumentText,
} from "../lib/embedder.ts";

const PROGRESS_EVERY_PAGES = 100;

const client = getClient();
const counts = new Map<string, number>();
const started = performance.now();
let afterId = Number(Deno.env.get("BACKFILL_AFTER_ID") ?? 0);
let pages = 0;

do {
  const page = await client.listAllLinks({
    afterId,
    limit: MAX_VECTORS_PER_WRITE,
  });

  const writes: LinkVectorWrite[] = [];
  for (const link of page.links) {
    writes.push({
      linkId: link.id,
      textFingerprint: linkTextFingerprint(link.title, link.description),
      vector: await embedText(linkDocumentText(link.title, link.description)),
    });
  }
  for (const { code } of await client.putLinkVectors(EMBEDDING_MODEL, writes)) {
    counts.set(code, (counts.get(code) ?? 0) + 1);
  }

  afterId = page.nextAfterId;
  if (++pages % PROGRESS_EVERY_PAGES === 0) {
    console.log(JSON.stringify({ afterId, ...Object.fromEntries(counts) }));
  }
} while (afterId !== 0);

console.log(JSON.stringify({
  seconds: Math.round((performance.now() - started) / 1000),
  results: Object.fromEntries(counts),
}));
Deno.exit(0);
