import { DmozClient } from "../../web/lib/dmoz-client.ts";

const LIMIT = 20;

const host = Deno.env.get("DMOZDB_HOST") ?? "127.0.0.1";
const port = Number(Deno.env.get("DMOZDB_PORT") ?? 18080);
const outDir = new URL("./out/", import.meta.url);
const client = new DmozClient(host, port);

const questions = (await Deno.readTextFile(new URL("questions.jsonl", outDir)))
  .split("\n")
  .filter((line) => line.trim())
  .map((line) => JSON.parse(line));

const rows: string[] = [];
for (const q of questions) {
  const started = performance.now();
  const result = await client.search(q.query, { limit: LIMIT, scope: "links" })
    .catch(() => ({ links: [] }));
  rows.push(
    JSON.stringify({
      qid: q.qid,
      ids: result.links.map((l) => l.id),
      ms: performance.now() - started,
    }),
  );
}

await Deno.writeTextFile(
  new URL("run_dmozdb.jsonl", outDir),
  rows.join("\n") + "\n",
);
console.log(`searched ${rows.length} questions`);
