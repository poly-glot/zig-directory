import { DmozClient } from "../../web/lib/dmoz-client.ts";
import { embedQuery } from "../../web/lib/embedder.ts";

const LIMIT = 20;
const OUTPUT_FILE = {
  all_terms: "run_dmozdb.jsonl",
  ranked: "run_dmozdb_ranked.jsonl",
  hybrid: "run_dmozdb_hybrid.jsonl",
} as const;
type Mode = keyof typeof OUTPUT_FILE;

const host = Deno.env.get("DMOZDB_HOST") ?? "127.0.0.1";
const port = Number(Deno.env.get("DMOZDB_PORT") ?? 18080);
const requested = Deno.env.get("SEARCH_MODE") ?? "all_terms";
const mode: Mode = requested in OUTPUT_FILE ? requested as Mode : "all_terms";
const outDir = new URL("./out/", import.meta.url);
const client = new DmozClient(host, port);

async function readJsonl(name: string): Promise<Record<string, unknown>[]> {
  const text = await Deno.readTextFile(new URL(name, outDir)).catch(() => "");
  return text.split("\n").filter((line) => line.trim()).map((line) =>
    JSON.parse(line)
  );
}

function percentile(values: number[], p: number): number {
  const sorted = values.toSorted((a, b) => a - b);
  return Math.round(sorted[Math.floor((sorted.length - 1) * p)] ?? 0);
}

const questions = [
  ...await readJsonl("questions.jsonl"),
  ...(mode === "hybrid" ? await readJsonl("multihop_questions.jsonl") : []),
];

const rows: string[] = [];
const searchMs: number[] = [];
const embedMs: number[] = [];
let vectorUsed = 0;
for (const q of questions) {
  const query = q.query as string;

  const embedStarted = performance.now();
  const queryEmbedding = mode === "hybrid"
    ? await embedQuery(query)
    : undefined;
  embedMs.push(performance.now() - embedStarted);

  const started = performance.now();
  const result = await client.search(query, {
    limit: LIMIT,
    scope: "links",
    mode: mode === "all_terms" ? "all_terms" : "ranked",
    queryEmbedding,
  }).catch(() => ({ links: [], vectorUsed: false }));
  searchMs.push(performance.now() - started);

  if (result.vectorUsed) vectorUsed++;
  rows.push(JSON.stringify({ qid: q.qid, ids: result.links.map((l) => l.id) }));
}

await Deno.writeTextFile(
  new URL(OUTPUT_FILE[mode], outDir),
  rows.join("\n") + "\n",
);
console.log(JSON.stringify({
  searched: rows.length,
  vectorUsed,
  searchMs: { p50: percentile(searchMs, 0.5), p95: percentile(searchMs, 0.95) },
  embedMs: { p50: percentile(embedMs, 0.5), p95: percentile(embedMs, 0.95) },
}));
Deno.exit(0);
