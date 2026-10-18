import { extractEntities } from "../../web/lib/entities.ts";

const sampleUrl = new URL("./entity_sample.jsonl", import.meta.url);
const outUrl = new URL(
  "./out/entity_predictions_native.jsonl",
  import.meta.url,
);

const rows = (await Deno.readTextFile(sampleUrl)).split("\n").filter((l) => l)
  .map((l) => JSON.parse(l));
const lines: string[] = [];
const started = performance.now();
for (const row of rows) {
  const entities = await extractEntities(row.title, row.description);
  lines.push(JSON.stringify({ id: row.id, ...entities }));
}
await Deno.writeTextFile(outUrl, lines.join("\n") + "\n");
console.log(JSON.stringify({
  links: rows.length,
  msPerLink: Math.round((performance.now() - started) / rows.length * 10) / 10,
}));
Deno.exit(0);
