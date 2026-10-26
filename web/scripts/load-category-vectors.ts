import { getClient, MAX_VECTORS_PER_WRITE } from "../lib/dmoz-client.ts";
import { EMBEDDING_DIMS } from "../lib/dmoz-client.ts";
import { EMBEDDING_MODEL } from "../lib/embedder.ts";

const PROGRESS_EVERY = 20_000;
const VERIFY_SAMPLE = 200;

const idsPath = Deno.env.get("CATEGORY_IDS") ?? "";
const vectorsPath = Deno.env.get("CATEGORY_VECTORS") ?? "";
if (!idsPath || !vectorsPath) {
  console.error(
    "CATEGORY_IDS=<row\\tid\\tslugpath.tsv> CATEGORY_VECTORS=<rows x 384 f32> are required",
  );
  Deno.exit(2);
}

const rows = (await Deno.readTextFile(idsPath)).split("\n").filter(Boolean).map(
  (line) => {
    const [row, id, path] = line.split("\t");
    return { row: Number(row), id: Number(id), path };
  },
);
const vectors = await Deno.open(vectorsPath);
const rowBytes = EMBEDDING_DIMS * 4;

async function vectorAt(row: number): Promise<Float32Array> {
  const buf = new Uint8Array(rowBytes);
  await vectors.seek(row * rowBytes, Deno.SeekMode.Start);
  let got = 0;
  while (got < rowBytes) {
    const n = await vectors.read(buf.subarray(got));
    if (n === null) throw new Error(`vectors file ends before row ${row}`);
    got += n;
  }
  return new Float32Array(buf.buffer);
}

const client = getClient();
const created = rows.filter((r) => r.id !== 0);

const sample = created.filter((_, i) =>
  i % Math.ceil(created.length / VERIFY_SAMPLE) === 0
);
for (const r of sample) {
  const found = await client.browsePathIfFound(r.path.replace(/^top\//, ""));
  if (found?.category.id !== r.id) {
    console.error(
      JSON.stringify({ mismatch: r, found: found?.category.id ?? null }),
    );
    Deno.exit(1);
  }
}
console.log(
  JSON.stringify({ verified: sample.length, toWrite: created.length }),
);

const counts = new Map<string, number>();
const started = performance.now();
let written = 0;
for (let i = 0; i < created.length; i += MAX_VECTORS_PER_WRITE) {
  const batch = created.slice(i, i + MAX_VECTORS_PER_WRITE);
  const writes = [];
  for (const r of batch) {
    writes.push({ categoryId: r.id, vector: await vectorAt(r.row) });
  }
  for (
    const { code } of await client.putCategoryVectors(EMBEDDING_MODEL, writes)
  ) {
    counts.set(code, (counts.get(code) ?? 0) + 1);
  }
  written += batch.length;
  if (written % PROGRESS_EVERY < MAX_VECTORS_PER_WRITE) {
    console.log(JSON.stringify({ written, ...Object.fromEntries(counts) }));
  }
}
vectors.close();
console.log(JSON.stringify({
  seconds: Math.round((performance.now() - started) / 1000),
  written,
  results: Object.fromEntries(counts),
}));
Deno.exit(0);
