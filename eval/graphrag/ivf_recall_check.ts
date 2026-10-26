import { DmozClient } from "../../web/lib/dmoz-client.ts";
import { EMBEDDING_MODEL } from "../../web/lib/embedder.ts";

const LIMIT = 20;
const TOP = 10;
const MAX_URL_BYTES = 64;

const host = Deno.env.get("DMOZDB_HOST") ?? "127.0.0.1";
const port = Number(Deno.env.get("DMOZDB_PORT") ?? 18080);
const truthPath = Deno.env.get("TRUTH") ?? "";
const linksPath = Deno.env.get("LINKS_JSONL") ?? "";
if (!truthPath || !linksPath) {
  console.error("TRUTH=<truth.json> LINKS_JSONL=<links.jsonl> are required");
  Deno.exit(2);
}
const outDir = new URL("./out/", import.meta.url);

async function readJsonl(url: URL): Promise<Record<string, unknown>[]> {
  const text = await Deno.readTextFile(url);
  return text.split("\n").filter((l) => l.trim()).map((l) => JSON.parse(l));
}

async function urlsForRows(
  path: string,
  rows: Set<number>,
): Promise<Map<number, string>> {
  const found = new Map<number, string>();
  const file = await Deno.open(path);
  const decoder = new TextDecoder();
  const buf = new Uint8Array(1 << 20);
  let pending = "";
  let row = 0;
  while (true) {
    const n = await file.read(buf);
    if (n === null) break;
    pending += decoder.decode(buf.subarray(0, n), { stream: true });
    const lines = pending.split("\n");
    pending = lines.pop() ?? "";
    for (const line of lines) {
      if (rows.has(row)) found.set(row, JSON.parse(line).url);
      row++;
    }
  }
  file.close();
  return found;
}

function percentile(values: number[], p: number): number {
  const sorted = values.toSorted((a, b) => a - b);
  return Math.round(sorted[Math.floor((sorted.length - 1) * p)] ?? 0);
}

const truth = JSON.parse(await Deno.readTextFile(truthPath)) as {
  truth: number[][];
};
const needed = new Set(truth.truth.flatMap((rows) => rows.slice(0, TOP)));
const urlByRow = await urlsForRows(linksPath, needed);

const questions = [
  ...await readJsonl(new URL("questions.jsonl", outDir)),
  ...await readJsonl(new URL("multihop_questions.jsonl", outDir)),
];
const textByQid = new Map(
  questions.map((q) => [q.qid as string, q.query as string]),
);
const vectors = await readJsonl(new URL("query_vectors.jsonl", outDir));

const client = new DmozClient(host, port);
const encoder = new TextEncoder();
const searchMs: number[] = [];
let vectorUsed = 0;
let reachable = 0;
let hits = 0;
for (const [i, q] of vectors.entries()) {
  const query = textByQid.get(q.qid as string) ?? "";
  const started = performance.now();
  const result = await client.search(query, {
    limit: LIMIT,
    scope: "links",
    queryEmbedding: {
      model: EMBEDDING_MODEL,
      vector: Float32Array.from(q.vector as number[]),
    },
  });
  searchMs.push(performance.now() - started);
  if (result.vectorUsed) vectorUsed++;

  const returned = new Set(result.links.map((l) => l.url));
  for (const row of truth.truth[i].slice(0, TOP)) {
    const url = urlByRow.get(row) ?? "";
    if (encoder.encode(url).length > MAX_URL_BYTES) continue;
    reachable++;
    if (returned.has(url)) hits++;
  }
}

console.log(JSON.stringify({
  queries: vectors.length,
  vectorUsed,
  truthRows: vectors.length * TOP,
  reachableTruthRows: reachable,
  truthRowsInTop20: hits,
  recallOfReachable: Number((hits / reachable).toFixed(3)),
  searchMs: { p50: percentile(searchMs, 0.5), p95: percentile(searchMs, 0.95) },
}));
Deno.exit(0);
