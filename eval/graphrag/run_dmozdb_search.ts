import { DmozClient, type QueryEmbedding } from "../../web/lib/dmoz-client.ts";
import { EMBEDDING_MODEL } from "./embedding_model.ts";

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

async function queryEmbeddings(): Promise<Map<string, QueryEmbedding>> {
  const rows = await readJsonl("query_vectors.jsonl");
  return new Map(rows.map((row) => [
    row.qid as string,
    {
      model: EMBEDDING_MODEL,
      vector: Float32Array.from(row.vector as number[]),
    },
  ]));
}

const questions = [
  ...await readJsonl("questions.jsonl"),
  ...(mode === "hybrid" ? await readJsonl("multihop_questions.jsonl") : []),
];
const embeddings = mode === "hybrid" ? await queryEmbeddings() : new Map();

const rows: string[] = [];
let vectorUsed = 0;
for (const q of questions) {
  const started = performance.now();
  const result = await client.search(q.query as string, {
    limit: LIMIT,
    scope: "links",
    mode: mode === "all_terms" ? "all_terms" : "ranked",
    queryEmbedding: embeddings.get(q.qid as string),
  }).catch(() => ({ links: [], vectorUsed: false }));
  if (result.vectorUsed) vectorUsed++;
  rows.push(
    JSON.stringify({
      qid: q.qid,
      ids: result.links.map((l) => l.id),
      ms: performance.now() - started,
    }),
  );
}

await Deno.writeTextFile(
  new URL(OUTPUT_FILE[mode], outDir),
  rows.join("\n") + "\n",
);
console.log(`searched ${rows.length} questions (${vectorUsed} used vectors)`);
Deno.exit(0);
